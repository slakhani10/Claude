# Runs on every cold start of the Function App.
# Authenticate with the app's system-assigned managed identity so the
# collector can discover VMs (Reader role) and write to blob storage
# (Storage Blob Data Contributor role).
if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
}
