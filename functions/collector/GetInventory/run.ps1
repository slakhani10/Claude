<#
.SYNOPSIS
    Aggregates every per-region snapshot blob into a single JSON feed for the
    dashboard.

.DESCRIPTION
    Each regional collector writes inventory/regions/<region>.json into the
    central storage account (the one account reachable from all regions).
    This HTTP function lists those blobs, merges them, and returns one
    document:

        {
          "generatedAt": "...",
          "regions":  [ { "region", "collectedAt", "serverCount" }, ... ],
          "servers":  [ ...every server from every region... ]
        }

    Deploy it with (any one of) the regional function apps - it only needs to
    reach the storage account, not the servers. Call it from the dashboard:

        GET https://<app>.azurewebsites.net/api/GetInventory?code=<function key>
#>
using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

$storageAccount = $env:INVENTORY_STORAGE_ACCOUNT
$container      = if ($env:INVENTORY_CONTAINER) { $env:INVENTORY_CONTAINER } else { 'inventory' }

try {
    $storageContext = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount
    $blobs = Get-AzStorageBlob -Context $storageContext -Container $container -Prefix 'regions/'

    $regions = [System.Collections.Generic.List[object]]::new()
    $servers = [System.Collections.Generic.List[object]]::new()

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        foreach ($blob in $blobs) {
            $localPath = Join-Path $tempDir ([IO.Path]::GetFileName($blob.Name))
            Get-AzStorageBlobContent -Context $storageContext -Container $container `
                -Blob $blob.Name -Destination $localPath -Force | Out-Null

            $snapshot = Get-Content -Path $localPath -Raw | ConvertFrom-Json

            $regions.Add([ordered]@{
                region      = $snapshot.region
                collectedAt = $snapshot.collectedAt
                serverCount = $snapshot.serverCount
            })
            foreach ($server in $snapshot.servers) {
                $server | Add-Member -NotePropertyName region -NotePropertyValue $snapshot.region -Force
                $server | Add-Member -NotePropertyName collectedAt -NotePropertyValue $snapshot.collectedAt -Force
                $servers.Add($server)
            }
        }
    }
    finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $body = [ordered]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        regions     = $regions
        servers     = $servers
    } | ConvertTo-Json -Depth 10

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{
            'Content-Type'                = 'application/json'
            # Lock this down to your dashboard's origin once deployed.
            'Access-Control-Allow-Origin' = '*'
            'Cache-Control'               = 'no-cache'
        }
        Body       = $body
    })
}
catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{ error = $_.Exception.Message } | ConvertTo-Json)
    })
}
