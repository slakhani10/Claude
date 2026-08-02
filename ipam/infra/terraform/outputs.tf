output "web_app_name" {
  description = "Name of the web app, for az webapp commands."
  value       = azurerm_linux_web_app.main.name
}

output "web_app_url" {
  description = <<-EOT
    URL of the allocator. Once webapp_public_network_access_enabled is false
    this name resolves to the private endpoint, and only from inside the VNet.
  EOT
  value       = "https://${azurerm_linux_web_app.main.default_hostname}"
}

output "web_app_private_ip" {
  description = "Private IP the web app's private endpoint answers on."
  value       = azurerm_private_endpoint.webapp.private_service_connection[0].private_ip_address
}

output "storage_account_name" {
  description = "Storage account holding the site and VLAN tables."
  value       = azurerm_storage_account.main.name
}

output "storage_table_private_ip" {
  description = "Private IP of the storage account's table private endpoint."
  value       = azurerm_private_endpoint.storage_table.private_service_connection[0].private_ip_address
}

output "vnet_id" {
  description = "VNet ID, for peering or linking additional DNS zones."
  value       = azurerm_virtual_network.main.id
}

output "management_subnet_id" {
  description = "Empty subnet for a jumpbox or self-hosted deployment agent."
  value       = azurerm_subnet.management.id
}
