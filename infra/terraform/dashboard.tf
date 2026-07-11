# Uploads the dashboard to the storage account's static website ($web).
# Re-uploads automatically whenever a file's content changes.

locals {
  dashboard_dir = "${path.module}/../../dashboard"

  content_types = {
    ".html" = "text/html"
    ".css"  = "text/css"
    ".js"   = "application/javascript"
    ".json" = "application/json"
  }
}

resource "azurerm_storage_blob" "dashboard" {
  for_each = fileset(local.dashboard_dir, "*")

  name                 = each.value
  storage_container_id = "${azurerm_storage_account.central.primary_blob_endpoint}$web"
  type                 = "Block"
  source               = "${local.dashboard_dir}/${each.value}"
  content_md5          = filemd5("${local.dashboard_dir}/${each.value}")
  content_type = lookup(
    local.content_types,
    lower(try(regex("\\.[^.]+$", each.value), "")),
    "application/octet-stream"
  )

  depends_on = [azurerm_storage_account_static_website.dashboard]
}
