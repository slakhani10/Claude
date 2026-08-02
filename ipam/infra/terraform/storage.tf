# Storage account holding the site allocations, reachable only over a private
# endpoint on the table sub-resource.
#
# Shared keys are disabled: the web app authenticates with its managed
# identity against the "Storage Table Data Contributor" role assigned below,
# so no key or connection string exists to leak.
#
# The tables themselves are NOT created here. Table creation is a data-plane
# call, and the data plane is private - Terraform running on your laptop
# cannot reach it. The app creates its tables on first use instead.

resource "random_string" "storage_suffix" {
  length  = 6
  lower   = true
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_storage_account" "main" {
  name                     = "${var.name_prefix}st${random_string.storage_suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
  account_kind             = "StorageV2"
  tags                     = var.tags

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  public_network_access_enabled   = var.storage_public_network_access_enabled
}

resource "azurerm_private_endpoint" "storage_table" {
  name                = "${var.name_prefix}-pe-table"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "table"
    private_connection_resource_id = azurerm_storage_account.main.id
    subresource_names              = ["table"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "table"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["table"].id]
  }
}

# The web app's identity is the only thing that ever reads or writes the tables.
resource "azurerm_role_assignment" "app_table_contributor" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_linux_web_app.main.identity[0].principal_id
}
