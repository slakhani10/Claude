# VNet for the Site IP Allocator.
#
# Three subnets:
#   private-endpoints - inbound PEs for the web app and the storage account
#   app-integration   - delegated to App Service; the app's outbound path
#   management        - empty; where a jumpbox or self-hosted agent goes
#
# Plus the two private DNS zones that make the private endpoints resolvable.
# Without the VNet links, clients inside the VNet would still resolve the
# public IPs and the whole arrangement would quietly not work.

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.name_prefix}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.private_endpoint_subnet_prefix]

  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "app_integration" {
  name                 = "snet-app-integration"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.app_integration_subnet_prefix]

  delegation {
    name = "appservice"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnetAction/join/action"]
    }
  }
}

resource "azurerm_subnet" "management" {
  name                 = "snet-management"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.management_subnet_prefix]
}

# ------------------------------------------------------------- NSGs
# The private endpoint subnet carries no NSG on purpose: NSG rules on PE
# subnets are a well-known source of silent breakage, and the endpoints are
# already unreachable from outside the VNet.
resource "azurerm_network_security_group" "management" {
  name                = "${var.name_prefix}-nsg-management"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  # Deliberately no inbound allow rules. Add your own (Bastion, VPN, or an
  # ExpressRoute source range) rather than opening RDP/SSH to the internet.
}

resource "azurerm_subnet_network_security_group_association" "management" {
  subnet_id                 = azurerm_subnet.management.id
  network_security_group_id = azurerm_network_security_group.management.id
}

# --------------------------------------------------------- private DNS zones
locals {
  private_dns_zones = {
    sites = "privatelink.azurewebsites.net"
    table = "privatelink.table.core.windows.net"
  }
}

resource "azurerm_private_dns_zone" "zones" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "links" {
  for_each              = local.private_dns_zones
  name                  = "link-${each.key}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.zones[each.key].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}
