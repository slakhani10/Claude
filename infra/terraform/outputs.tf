output "dashboard_url" {
  description = "Static-website URL of the dashboard. Resolves to a private endpoint from linked VNets once public access is disabled."
  value       = azurerm_storage_account.central.primary_web_endpoint
}

output "storage_account_name" {
  value = azurerm_storage_account.central.name
}

output "function_app_hostnames" {
  description = "Per-region function app hostnames. Use any one of them for the GetInventory URL in dashboard/config.js."
  value = {
    for region, app in azurerm_windows_function_app.regional :
    region => app.default_hostname
  }
}

output "function_app_private_endpoint_ips" {
  description = "Private IP of each function app's inbound private endpoint."
  value = {
    for region, pe in azurerm_private_endpoint.function_app :
    region => pe.private_service_connection[0].private_ip_address
  }
}
