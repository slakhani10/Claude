<#
.SYNOPSIS
    End-to-end deployment for the Azure Server Inventory solution.

.DESCRIPTION
    1. Deploys infra/main.bicep (central storage + one VNet-integrated
       PowerShell Function App per region).
    2. Grants each Function App's managed identity Reader on the subscription
       so it can discover the VMs in its region.
    3. Zip-deploys the collector/aggregator function code to every app.
    4. Enables the storage account's static website and uploads the dashboard.

.EXAMPLE
    ./deploy.ps1 -ResourceGroupName rg-server-inventory -NamePrefix srvinv `
        -HubLocation eastus `
        -Regions @(
            @{ name = 'eastus';     subnetId = '/subscriptions/<sub>/resourceGroups/rg-net-eus/providers/Microsoft.Network/virtualNetworks/vnet-eus/subnets/snet-functions' }
            @{ name = 'westeurope'; subnetId = '/subscriptions/<sub>/resourceGroups/rg-net-weu/providers/Microsoft.Network/virtualNetworks/vnet-weu/subnets/snet-functions' }
        ) `
        -WmiUsername 'CORP\svc-inventory'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]    $ResourceGroupName,
    [Parameter(Mandatory)] [string]    $NamePrefix,
    [Parameter(Mandatory)] [string]    $HubLocation,
    [Parameter(Mandatory)] [hashtable[]] $Regions,
    [Parameter(Mandatory)] [string]    $WmiUsername,
    [securestring]                     $WmiPassword
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

if (-not $WmiPassword) {
    $WmiPassword = Read-Host -Prompt "Password for $WmiUsername" -AsSecureString
}

# ---------------------------------------------------------------- 1. infra
Write-Host "Deploying infrastructure to resource group '$ResourceGroupName'..."
New-AzResourceGroup -Name $ResourceGroupName -Location $HubLocation -Force | Out-Null

$deployment = New-AzResourceGroupDeployment `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile (Join-Path $PSScriptRoot 'main.bicep') `
    -namePrefix $NamePrefix `
    -hubLocation $HubLocation `
    -regions $Regions `
    -wmiUsername $WmiUsername `
    -wmiPassword $WmiPassword

$storageAccountName = $deployment.Outputs.storageAccountName.Value
$functionAppNames   = @($deployment.Outputs.functionAppNames.Value)
$principalIds       = @($deployment.Outputs.functionAppPrincipalIds.Value)

# ------------------------------------------- 2. Reader role for VM discovery
$subscriptionScope = "/subscriptions/$((Get-AzContext).Subscription.Id)"
foreach ($principalId in $principalIds) {
    $existing = Get-AzRoleAssignment -ObjectId $principalId -Scope $subscriptionScope `
                    -RoleDefinitionName Reader -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-AzRoleAssignment -ObjectId $principalId -Scope $subscriptionScope `
            -RoleDefinitionName Reader | Out-Null
    }
}
Write-Host "Reader role assigned to $($principalIds.Count) function app identities."

# --------------------------------------------------- 3. deploy function code
$zipPath = Join-Path ([IO.Path]::GetTempPath()) 'server-inventory-functions.zip'
if (Test-Path $zipPath) { Remove-Item $zipPath }
Compress-Archive -Path (Join-Path $repoRoot 'functions/collector/*') -DestinationPath $zipPath

foreach ($appName in $functionAppNames) {
    Write-Host "Deploying function code to $appName..."
    Publish-AzWebApp -ResourceGroupName $ResourceGroupName -Name $appName `
        -ArchivePath $zipPath -Force | Out-Null
}

# --------------------------------------------------------- 4. dashboard site
Write-Host 'Enabling static website and uploading dashboard...'
$storageContext = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName `
                    -Name $storageAccountName).Context
Enable-AzStorageStaticWebsite -Context $storageContext -IndexDocument 'index.html'

Get-ChildItem (Join-Path $repoRoot 'dashboard') -File | ForEach-Object {
    $contentType = switch ($_.Extension) {
        '.html' { 'text/html' }
        '.css'  { 'text/css' }
        '.js'   { 'application/javascript' }
        default { 'application/octet-stream' }
    }
    Set-AzStorageBlobContent -Context $storageContext -Container '$web' `
        -File $_.FullName -Blob $_.Name `
        -Properties @{ ContentType = $contentType } -Force | Out-Null
}

$webEndpoint = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName `
                 -Name $storageAccountName).PrimaryEndpoints.Web

Write-Host ''
Write-Host '=================================================================='
Write-Host " Dashboard:      $webEndpoint"
Write-Host " Function apps:  $($functionAppNames -join ', ')"
Write-Host ''
Write-Host ' Next steps:'
Write-Host '  1. Get a function key for GetInventory on ONE of the apps and'
Write-Host '     put its full URL into dashboard/config.js (apiUrl), then'
Write-Host '     re-run step 4 (or re-run this script).'
Write-Host '  2. Move WMI_PASSWORD to a Key Vault reference on each app.'
Write-Host '  3. Confirm WinRM (TCP 5985/5986) is open from each function'
Write-Host '     subnet to the servers in the SAME region only.'
Write-Host '=================================================================='
