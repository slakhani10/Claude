<#
.SYNOPSIS
    Regional server inventory collector.

.DESCRIPTION
    Runs inside the Function App deployed to ONE Azure region (the app is
    VNet-integrated into that region, so it can reach servers that regional
    firewalls hide from every other region).

    For every running Windows VM in its region it opens a CIM/WMI session and
    collects:
      - Win32_OperatingSystem : real OS Caption, Version, BuildNumber
      - Win32_Processor       : physical core count (summed across sockets)
      - Win32_ComputerSystem  : memory / domain
      - Win32_Service + StdRegProv : SQL Server presence, instance names,
        Edition, Version and PatchLevel (all over WMI - no SQL login needed)

    The result is written to the CENTRAL blob storage account (reachable from
    all regions) as inventory/regions/<region>.json. The GetInventory HTTP
    function and the dashboard aggregate those per-region blobs.

.NOTES
    Required app settings:
      INVENTORY_REGION           e.g. "eastus" - the region this app owns
      INVENTORY_STORAGE_ACCOUNT  name of the central storage account
      WMI_USERNAME               account with remote WMI rights (DOMAIN\user or .\localadmin)
      WMI_PASSWORD               Key Vault reference strongly recommended:
                                 @Microsoft.KeyVault(SecretUri=...)
    Optional:
      INVENTORY_CONTAINER        blob container (default: inventory)
      COLLECTOR_THROTTLE         parallel WMI sessions (default: 8)
      WMI_TRANSPORT              Wsman (default) or Dcom
#>
param($Timer)

$ErrorActionPreference = 'Stop'

$region         = $env:INVENTORY_REGION
$storageAccount = $env:INVENTORY_STORAGE_ACCOUNT
$container      = if ($env:INVENTORY_CONTAINER) { $env:INVENTORY_CONTAINER } else { 'inventory' }
$throttle       = if ($env:COLLECTOR_THROTTLE)  { [int]$env:COLLECTOR_THROTTLE } else { 8 }
$transport      = if ($env:WMI_TRANSPORT)       { $env:WMI_TRANSPORT } else { 'Wsman' }

foreach ($required in 'INVENTORY_REGION', 'INVENTORY_STORAGE_ACCOUNT', 'WMI_USERNAME', 'WMI_PASSWORD') {
    if (-not (Get-Item "env:$required" -ErrorAction SilentlyContinue).Value) {
        throw "App setting '$required' is not configured."
    }
}

$credential = [pscredential]::new(
    $env:WMI_USERNAME,
    (ConvertTo-SecureString $env:WMI_PASSWORD -AsPlainText -Force))

Write-Host "Inventory collection starting for region '$region'."

# ---------------------------------------------------------------------------
# 1. Discover running Windows VMs in this region and their private IPs
# ---------------------------------------------------------------------------
$vms = Get-AzVM -Status | Where-Object {
    $_.Location -eq $region -and
    $_.StorageProfile.OsDisk.OsType -eq 'Windows' -and
    $_.PowerState -eq 'VM running'
}

Write-Host "Discovered $($vms.Count) running Windows VM(s) in $region."

# Map NIC resource id -> primary private IP (one NIC listing, not one per VM)
$nicIpByToken = @{}
foreach ($nic in Get-AzNetworkInterface) {
    $primaryIp = ($nic.IpConfigurations | Where-Object Primary | Select-Object -First 1).PrivateIpAddress
    if (-not $primaryIp) { $primaryIp = $nic.IpConfigurations[0].PrivateIpAddress }
    $nicIpByToken[$nic.Id.ToLowerInvariant()] = $primaryIp
}

$targets = foreach ($vm in $vms) {
    $nicId = ($vm.NetworkProfile.NetworkInterfaces | Where-Object { $_.Primary -ne $false } |
              Select-Object -First 1).Id
    [pscustomobject]@{
        Name          = $vm.Name
        ResourceGroup = $vm.ResourceGroupName
        VmSize        = $vm.HardwareProfile.VmSize
        IpAddress     = if ($nicId) { $nicIpByToken[$nicId.ToLowerInvariant()] } else { $null }
    }
}

# ---------------------------------------------------------------------------
# 2. Collect WMI facts from each server in parallel
# ---------------------------------------------------------------------------
$servers = $targets | ForEach-Object -ThrottleLimit $throttle -Parallel {
    $target     = $_
    $credential = $using:credential
    $transport  = $using:transport

    $record = [ordered]@{
        name              = $target.Name
        resourceGroup     = $target.ResourceGroup
        vmSize            = $target.VmSize
        ipAddress         = $target.IpAddress
        osCaption         = $null
        osVersion         = $null
        osBuild           = $null
        cores             = $null
        logicalProcessors = $null
        memoryGB          = $null
        domain            = $null
        lastBoot          = $null
        sql               = [ordered]@{ installed = $false; instances = @() }
        collectionError   = $null
    }

    $session = $null
    try {
        if (-not $target.IpAddress) { throw 'No private IP address found for VM.' }

        $sessionOptions = New-CimSessionOption -Protocol $transport
        $session = New-CimSession -ComputerName $target.IpAddress `
                                  -Credential $credential `
                                  -SessionOption $sessionOptions `
                                  -OperationTimeoutSec 45

        # --- Operating system: the ACTUAL installed caption, straight from WMI
        $os = Get-CimInstance -CimSession $session `
                -Query 'SELECT Caption, Version, BuildNumber, LastBootUpTime FROM Win32_OperatingSystem'
        $record.osCaption = $os.Caption.Trim()
        $record.osVersion = $os.Version
        $record.osBuild   = $os.BuildNumber
        $record.lastBoot  = if ($os.LastBootUpTime) { $os.LastBootUpTime.ToUniversalTime().ToString('o') }

        # --- CPU: physical cores in use (summed across all sockets)
        $cpus = Get-CimInstance -CimSession $session `
                  -Query 'SELECT NumberOfCores, NumberOfLogicalProcessors FROM Win32_Processor'
        $record.cores             = ($cpus | Measure-Object NumberOfCores -Sum).Sum
        $record.logicalProcessors = ($cpus | Measure-Object NumberOfLogicalProcessors -Sum).Sum

        # --- Memory / domain
        $cs = Get-CimInstance -CimSession $session `
                -Query 'SELECT TotalPhysicalMemory, Domain FROM Win32_ComputerSystem'
        $record.memoryGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $record.domain   = $cs.Domain

        # --- SQL Server detection via the service list (still WMI)
        $sqlServices = Get-CimInstance -CimSession $session -Query (
            'SELECT Name, State, StartMode FROM Win32_Service ' +
            "WHERE (Name = 'MSSQLSERVER' OR Name LIKE 'MSSQL$%') AND PathName LIKE '%sqlservr.exe%'")

        # Registry reads over WMI (StdRegProv) - HKEY_LOCAL_MACHINE
        $HKLM = [uint32]2147483650
        $readRegString = {
            param($subKey, $valueName)
            $r = Invoke-CimMethod -CimSession $session -Namespace 'root/default' `
                    -ClassName StdRegProv -MethodName GetStringValue `
                    -Arguments @{ hDefKey = $HKLM; sSubKeyName = $subKey; sValueName = $valueName }
            if ($r.ReturnValue -eq 0) { $r.sValue } else { $null }
        }

        foreach ($svc in $sqlServices) {
            $instanceName = if ($svc.Name -eq 'MSSQLSERVER') { 'MSSQLSERVER' }
                            else { $svc.Name.Split('$', 2)[1] }

            # Instance name -> instance id (e.g. MSSQL15.MSSQLSERVER), then Setup key
            $instanceId = & $readRegString `
                'SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' $instanceName

            $edition = $null; $version = $null; $patchLevel = $null
            if ($instanceId) {
                $setupKey   = "SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\Setup"
                $edition    = & $readRegString $setupKey 'Edition'
                $version    = & $readRegString $setupKey 'Version'
                $patchLevel = & $readRegString $setupKey 'PatchLevel'
            }

            $record.sql.installed  = $true
            $record.sql.instances += [ordered]@{
                instance     = $instanceName
                serviceState = $svc.State
                startMode    = $svc.StartMode
                edition      = $edition
                version      = if ($patchLevel) { $patchLevel } else { $version }
                baseVersion  = $version
            }
        }
    }
    catch {
        $record.collectionError = $_.Exception.Message
        Write-Warning "[$($target.Name)] $($_.Exception.Message)"
    }
    finally {
        if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
    }

    [pscustomobject]$record
}

$succeeded = @($servers | Where-Object { -not $_.collectionError }).Count
Write-Host "Collected $succeeded/$($targets.Count) servers successfully."

# ---------------------------------------------------------------------------
# 3. Publish the region snapshot to the central blob storage account
# ---------------------------------------------------------------------------
$payload = [ordered]@{
    region      = $region
    collectedAt = (Get-Date).ToUniversalTime().ToString('o')
    serverCount = @($servers).Count
    servers     = @($servers)
} | ConvertTo-Json -Depth 8

$tempFile = Join-Path ([IO.Path]::GetTempPath()) "$region.json"
$payload | Out-File -FilePath $tempFile -Encoding utf8 -Force

$storageContext = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount
Set-AzStorageBlobContent -Context $storageContext `
                         -Container $container `
                         -Blob "regions/$region.json" `
                         -File $tempFile `
                         -Properties @{ ContentType = 'application/json' } `
                         -Force | Out-Null

Write-Host "Snapshot uploaded to $container/regions/$region.json."
