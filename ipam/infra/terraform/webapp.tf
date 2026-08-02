# The allocator web app.
#
# Inbound:  a private endpoint on the "sites" sub-resource, so the site is only
#           reachable from inside the VNet (or anything peered/VPN'd to it).
#           That one endpoint covers both the app and its SCM/Kudu hostname.
# Outbound: regional VNet integration through the delegated subnet, with
#           vnet_route_all_enabled so traffic to storage takes the private
#           endpoint rather than the internet.

# App code, zip-deployed on every content change. Tests and caches are excluded
# so the package holds only what the site needs to run.
data "archive_file" "app_package" {
  type        = "zip"
  source_dir  = "${path.module}/../../app"
  output_path = "${path.module}/.build/app.zip"

  excludes = [
    "tests",
    "tests/test_allocator.py",
    "tests/test_storage.py",
    "__pycache__",
    ".pytest_cache",
  ]
}

resource "azurerm_service_plan" "main" {
  name                = "${var.name_prefix}-plan"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = var.app_service_sku
  tags                = var.tags
}

resource "azurerm_linux_web_app" "main" {
  name                = "${var.name_prefix}-app-${random_string.storage_suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main.id
  tags                = var.tags

  https_only                    = true
  public_network_access_enabled = var.webapp_public_network_access_enabled
  virtual_network_subnet_id     = azurerm_subnet.app_integration.id
  zip_deploy_file               = data.archive_file.app_package.output_path

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on              = true
    ftps_state             = "Disabled"
    minimum_tls_version    = "1.2"
    http2_enabled          = true
    vnet_route_all_enabled = true
    health_check_path      = "/api/health"

    application_stack {
      python_version = var.python_version
    }

    app_command_line = "gunicorn --bind=0.0.0.0:8000 --timeout 120 --workers 2 app:app"
  }

  app_settings = {
    # Oryx installs requirements.txt during zip deploy
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"

    # Resolve the storage private endpoint through Azure DNS, which is what
    # the private DNS zone links above are attached to.
    WEBSITE_DNS_SERVER = "168.63.129.16"

    IPAM_STORAGE_ACCOUNT = azurerm_storage_account.main.name
    IPAM_SITES_TABLE     = "sites"
    IPAM_VLANS_TABLE     = "vlans"
  }
}

# Inbound private endpoint for the app itself
resource "azurerm_private_endpoint" "webapp" {
  name                = "${var.name_prefix}-pe-app"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "sites"
    private_connection_resource_id = azurerm_linux_web_app.main.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sites"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["sites"].id]
  }
}

# Recommended next step: add an auth_settings_v2 block to the web app above so
# Entra ID sign-in is required, and being on the network isn't by itself
# authorisation. It needs an app registration (client ID + tenant), so it is
# described in the README rather than guessed at here. The app already reads
# the signed-in user from the X-MS-CLIENT-PRINCIPAL-NAME header Easy Auth
# injects, and records it against each allocation.
