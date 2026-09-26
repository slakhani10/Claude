# One PowerShell Function App per region.
#
# Outbound: regional VNet integration (functions_subnet_id) so the collector
#           reaches its own region's servers over WMI/WinRM - the only place
#           that traffic is allowed.
# Inbound:  a private endpoint per app, so the GetInventory HTTP endpoint is
#           only reachable from inside the network.
#
# Elastic Premium (EP1) because regional VNet integration is not available on
# the Consumption plan.

# Function code package, zip-deployed by Terraform on every content change
data "archive_file" "function_package" {
  type        = "zip"
  source_dir  = "${path.module}/../../functions/collector"
  output_path = "${path.module}/.build/functions.zip"
}

resource "azurerm_service_plan" "regional" {
  for_each            = var.regions
  name                = "${var.name_prefix}-plan-${each.key}"
  location            = each.key
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Windows"
  sku_name            = "EP1"
}

resource "azurerm_windows_function_app" "regional" {
  for_each            = var.regions
  name                = "${var.name_prefix}-func-${each.key}"
  location            = each.key
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.regional[each.key].id

  storage_account_name       = azurerm_storage_account.central.name
  storage_account_access_key = azurerm_storage_account.central.primary_access_key

  https_only                    = true
  functions_extension_version   = "~4"
  virtual_network_subnet_id     = each.value.functions_subnet_id
  public_network_access_enabled = var.public_network_access_enabled
  zip_deploy_file               = data.archive_file.function_package.output_path

  identity {
    type = "SystemAssigned"
  }

  site_config {
    ftps_state             = "Disabled"
    vnet_route_all_enabled = true

    application_stack {
      powershell_core_version = "7.4"
    }
  }

  app_settings = {
    WEBSITE_RUN_FROM_PACKAGE  = "1"
    INVENTORY_REGION          = each.key
    INVENTORY_STORAGE_ACCOUNT = azurerm_storage_account.central.name
    INVENTORY_CONTAINER       = azurerm_storage_container.inventory.name
    WMI_USERNAME              = var.wmi_username
    # Recommended post-deploy: replace with
    # "@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/wmi-password/)"
    WMI_PASSWORD = var.wmi_password

    # GetReservationSavings. Reservations are tenant-wide, so every app can
    # serve this endpoint; they share the cache blob in the central account.
    RESERVATION_COST_SCOPE    = var.reservation_cost_scope
    RESERVATION_CURRENCY      = var.reservation_currency
    RESERVATION_CACHE_MINUTES = var.reservation_cache_minutes
  }

  lifecycle {
    ignore_changes = [
      # keep hand-applied Key Vault reference for WMI_PASSWORD, if any
      app_settings["WMI_PASSWORD"],
    ]
  }
}

# Inbound private endpoint for each function app ("sites" sub-resource)
resource "azurerm_private_endpoint" "function_app" {
  for_each            = var.regions
  name                = "${var.name_prefix}-pe-func-${each.key}"
  location            = each.key
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = each.value.private_endpoint_subnet_id

  private_service_connection {
    name                           = "sites"
    private_connection_resource_id = azurerm_windows_function_app.regional[each.key].id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sites"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["sites"].id]
  }
}

# ------------------------------------------------------------------- RBAC
# Write region snapshots to the central account
resource "azurerm_role_assignment" "blob_contributor" {
  for_each             = var.regions
  scope                = azurerm_storage_account.central.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_windows_function_app.regional[each.key].identity[0].principal_id
}

# Discover the VMs in their region (Get-AzVM / Get-AzNetworkInterface)
resource "azurerm_role_assignment" "subscription_reader" {
  for_each             = var.regions
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azurerm_windows_function_app.regional[each.key].identity[0].principal_id
}

# Read amortized cost for the GetReservationSavings endpoint.
#
# This covers the app's own SUBSCRIPTION only. Reservations are usually shared
# across subscriptions and billed at the enrollment, so for complete numbers
# grant the same role at the billing scope and set reservation_cost_scope.
resource "azurerm_role_assignment" "cost_management_reader" {
  for_each             = var.regions
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Cost Management Reader"
  principal_id         = azurerm_windows_function_app.regional[each.key].identity[0].principal_id
}

# NOTE - Reservation Reader is NOT assignable here. Reservation orders live at
# /providers/Microsoft.Capacity, outside any subscription, so the azurerm
# provider cannot scope a role assignment to them. Grant it once by hand after
# the first apply, to each app's principal id (terraform output
# function_app_principal_ids):
#
#   az role assignment create --role "Reservations Reader" \
#     --assignee <principal id> \
#     --scope /providers/Microsoft.Capacity/reservationOrders/<order id>
#
# Or, to cover every current and future order at once, grant the principal
# Reservations Reader at the billing account scope in the portal:
#   Cost Management + Billing > <billing account> > Access control (IAM).
# Without it the endpoint returns an empty list and says so in "warnings".
