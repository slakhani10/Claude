# Azure Server Inventory - core infrastructure
#
# One central storage account is the ONLY cross-region data path (regional
# firewalls block region-to-region traffic). Every region gets private
# endpoints to it, so collector -> storage traffic never leaves private
# address space. The dashboard is the storage account's static website,
# also exposed through private endpoints ("web" sub-resource).

data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.hub_location
}

resource "random_string" "storage_suffix" {
  length  = 6
  lower   = true
  upper   = false
  special = false
}

# ---------------------------------------------------------------- storage
resource "azurerm_storage_account" "central" {
  name                     = "${var.name_prefix}inv${random_string.storage_suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true

  # Phase 1 (true): lets Terraform create containers / upload the dashboard
  # from your machine. Phase 2 (false): private endpoints only.
  public_network_access_enabled = var.public_network_access_enabled
}

resource "azurerm_storage_container" "inventory" {
  name               = "inventory"
  storage_account_id = azurerm_storage_account.central.id
}

# Static website hosting for the dashboard (creates the $web container)
resource "azurerm_storage_account_static_website" "dashboard" {
  storage_account_id = azurerm_storage_account.central.id
  index_document     = "index.html"
}

# ------------------------------------------------------- private DNS zones
# One zone each for function apps, blob, and static web; linked to every
# region's VNet so private-endpoint FQDNs resolve everywhere they're used.
locals {
  private_dns_zones = {
    sites = "privatelink.azurewebsites.net"
    blob  = "privatelink.blob.core.windows.net"
    web   = "privatelink.web.core.windows.net"
  }

  # zone x region matrix for the VNet links
  zone_links = {
    for pair in setproduct(keys(local.private_dns_zones), keys(var.regions)) :
    "${pair[0]}-${pair[1]}" => { zone = pair[0], region = pair[1] }
  }
}

resource "azurerm_private_dns_zone" "zones" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "links" {
  for_each              = local.zone_links
  name                  = "link-${each.value.zone}-${each.value.region}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.zones[each.value.zone].name
  virtual_network_id    = var.regions[each.value.region].vnet_id
}

# ------------------------------------ storage private endpoints, per region
# blob: collectors write their region snapshots privately
# web:  the dashboard static website is reachable privately from each region
resource "azurerm_private_endpoint" "storage_blob" {
  for_each            = var.regions
  name                = "${var.name_prefix}-pe-blob-${each.key}"
  location            = each.key
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = each.value.private_endpoint_subnet_id

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.central.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["blob"].id]
  }
}

resource "azurerm_private_endpoint" "storage_web" {
  for_each            = var.regions
  name                = "${var.name_prefix}-pe-web-${each.key}"
  location            = each.key
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = each.value.private_endpoint_subnet_id

  private_service_connection {
    name                           = "web"
    private_connection_resource_id = azurerm_storage_account.central.id
    subresource_names              = ["web"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "web"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["web"].id]
  }
}
