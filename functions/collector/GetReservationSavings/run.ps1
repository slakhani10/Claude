<#
.SYNOPSIS
    Serves the reservation cost and savings feed to the dashboard.

.DESCRIPTION
    Wraps the AzReservationSavings module (functions/collector/Modules) in an
    HTTP endpoint and returns one document:

        {
          "generatedAt": "...", "currency": "USD", "costMonth": "2026-08",
          "totals":       { monthlyCost, payGoMonthlyCost, monthlySaving, ... },
          "reservations": [ ...one row per active reservation... ],
          "warnings":     [ ...anything the dashboard should show the operator... ]
        }

    Reservations are tenant-wide, not regional, so - like GetInventory - this
    is deployed with every regional app and any one of them can serve it.

    RESULTS ARE CACHED in the central storage account, because a reservation's
    cost moves at most daily while the dashboard polls every 60 seconds, and
    the Cost Management query API throttles hard (429) under repeated calls.
    The first request after the TTL expires pays the full collection cost
    (tens of seconds); everything else is served from the blob. Pass
    ?refresh=true to force a recollection.

.NOTES
    Required app settings:
      INVENTORY_STORAGE_ACCOUNT   central storage account (for the cache blob)
    Optional:
      INVENTORY_CONTAINER         blob container (default: inventory)
      RESERVATION_COST_SCOPE      billing scope for Cost Management, e.g.
                                  /providers/Microsoft.Billing/billingAccounts/1234567
                                  (default: the app's own subscription)
      RESERVATION_CURRENCY        ISO currency for retail prices (default: USD)
      RESERVATION_CACHE_MINUTES   cache TTL (default: 360 = 6 hours)

    The app's managed identity needs Reservation Reader on the reservation
    orders, and Cost Management Reader on RESERVATION_COST_SCOPE for actual
    billed costs. Neither is a subscription role assignment - see the README.
#>
using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

$storageAccount = $env:INVENTORY_STORAGE_ACCOUNT
$container      = if ($env:INVENTORY_CONTAINER) { $env:INVENTORY_CONTAINER } else { 'inventory' }
$currency       = if ($env:RESERVATION_CURRENCY) { $env:RESERVATION_CURRENCY } else { 'USD' }
$cacheMinutes   = if ($env:RESERVATION_CACHE_MINUTES) { [int]$env:RESERVATION_CACHE_MINUTES } else { 360 }
$cacheBlob      = 'reservations/savings.json'

$forceRefresh = $Request.Query.refresh -in 'true', '1'

$headers = @{
    'Content-Type' = 'application/json'
    # Lock this down to your dashboard's origin once deployed.
    'Access-Control-Allow-Origin' = '*'
    'Cache-Control'               = 'no-cache'
}

function Write-JsonResponse {
    param([HttpStatusCode]$StatusCode, [string]$Body)

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = $headers
        Body       = $Body
    })
}

try {
    $storageContext = $null
    if ($storageAccount) {
        $storageContext = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount
    }
    else {
        Write-Warning 'INVENTORY_STORAGE_ACCOUNT is not set; serving uncached (every request recollects).'
    }

    # ---------------------------------------------------------------------
    # 1. Serve the cache when it is still fresh
    # ---------------------------------------------------------------------
    # Anything wrong with the cache - missing, unreadable, an unexpected
    # LastModified shape - means recollect, never fail the request. The cache
    # is an optimisation; the caller still wants an answer without it.
    $servedFromCache = $false
    if ($storageContext -and -not $forceRefresh) {
        try {
            $cached = Get-AzStorageBlob -Context $storageContext -Container $container `
                                        -Blob $cacheBlob -ErrorAction SilentlyContinue
            if ($cached -and $null -ne $cached.LastModified) {
                # Az.Storage hands back a DateTimeOffset; be tolerant of a plain
                # DateTime so a provider change cannot take the endpoint down.
                $modifiedUtc = if ($cached.LastModified -is [datetimeoffset]) {
                    $cached.LastModified.UtcDateTime
                } else {
                    ([datetime]$cached.LastModified).ToUniversalTime()
                }
                $ageMinutes = ((Get-Date).ToUniversalTime() - $modifiedUtc).TotalMinutes

                if ($ageMinutes -lt $cacheMinutes) {
                    Write-Host ("Serving cached savings ({0:N0} min old, TTL {1} min)." -f $ageMinutes, $cacheMinutes)
                    $tempFile = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n') + '.json')
                    try {
                        Get-AzStorageBlobContent -Context $storageContext -Container $container `
                            -Blob $cacheBlob -Destination $tempFile -Force | Out-Null
                        Write-JsonResponse -StatusCode ([HttpStatusCode]::OK) `
                                           -Body (Get-Content -Path $tempFile -Raw)
                        $servedFromCache = $true
                    }
                    finally {
                        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                    }
                }
                else {
                    Write-Host ("Cache is {0:N0} min old (TTL {1} min); recollecting." -f $ageMinutes, $cacheMinutes)
                }
            }
        }
        catch {
            Write-Warning "Could not read the cache blob, recollecting: $($_.Exception.Message)"
        }
    }
    if ($servedFromCache) { return }

    # ---------------------------------------------------------------------
    # 2. Collect
    # ---------------------------------------------------------------------
    $warnings = [System.Collections.Generic.List[string]]::new()

    $savingsParameters = @{ Currency = $currency }
    if ($env:RESERVATION_COST_SCOPE) { $savingsParameters.CostScope = $env:RESERVATION_COST_SCOPE }

    # Get-AzReservationSavings warns rather than throws when Cost Management
    # cannot break costs down by reservation, so relay those to the dashboard
    # instead of letting them vanish into the function log.
    $rows = @(Get-AzReservationSavings @savingsParameters -WarningVariable collectionWarnings -WarningAction SilentlyContinue)
    foreach ($warning in $collectionWarnings) { $warnings.Add([string]$warning) }

    if ($rows.Count -eq 0) {
        $warnings.Add('No active reservations were returned. If you expect some, check that this function app''s managed identity has Reservation Reader on the reservation orders.')
    }

    # ---------------------------------------------------------------------
    # 3. Shape the feed (camelCase, to match the inventory feed)
    # ---------------------------------------------------------------------
    $sum = { param($property) ($rows | Measure-Object -Property $property -Sum).Sum }

    $totalCost   = & $sum 'MonthlyCost'
    $totalPayGo  = & $sum 'PayGoMonthlyCost'
    $totalSaving = & $sum 'MonthlySaving'

    $totals = [ordered]@{
        count                 = $rows.Count
        monthlyCost           = $totalCost
        payGoMonthlyCost      = $totalPayGo
        monthlySaving         = $totalSaving
        annualSaving          = if ($null -ne $totalSaving) { [math]::Round($totalSaving * 12, 2) } else { $null }
        remainingTermSaving   = & $sum 'RemainingTermSaving'
        realizedMonthlySaving = & $sum 'RealizedMonthlySaving'
        savingPercent         = if ($totalPayGo -gt 0) { [math]::Round(($totalSaving / $totalPayGo) * 100, 1) } else { $null }
        underutilizedCount    = @($rows | Where-Object { $null -ne $_.UtilizationPercent -and $_.UtilizationPercent -lt 90 }).Count
    }

    $reservations = foreach ($row in $rows) {
        [ordered]@{
            name                  = $row.Name
            resourceType          = $row.ResourceType
            sku                   = $row.Sku
            region                = $row.Region
            quantity              = $row.Quantity
            term                  = $row.Term
            billingPlan           = $row.BillingPlan
            state                 = $row.State
            scope                 = $row.Scope
            instanceFlexibility   = $row.InstanceFlexibility
            autoRenew             = $row.AutoRenew
            effectiveDate         = if ($row.EffectiveDate) { $row.EffectiveDate.ToUniversalTime().ToString('o') } else { $null }
            expiryDate            = if ($row.ExpiryDate) { $row.ExpiryDate.ToUniversalTime().ToString('o') } else { $null }
            monthsRemaining       = $row.MonthsRemaining
            monthlyCost           = $row.MonthlyCost
            payGoHourlyRate       = $row.PayGoHourlyRate
            payGoMonthlyCost      = $row.PayGoMonthlyCost
            monthlySaving         = $row.MonthlySaving
            savingPercent         = $row.SavingPercent
            annualSaving          = $row.AnnualSaving
            remainingTermSaving   = $row.RemainingTermSaving
            utilizationPercent    = $row.UtilizationPercent
            realizedMonthlySaving = $row.RealizedMonthlySaving
            costSource            = $row.CostSource
            reservationOrderId    = $row.ReservationOrderId
            reservationId         = $row.ReservationId
            notes                 = $row.Notes
        }
    }

    $body = [ordered]@{
        generatedAt  = (Get-Date).ToUniversalTime().ToString('o')
        currency     = $currency
        costMonth    = if ($rows.Count) { $rows[0].CostMonth } else { $null }
        costScope    = if ($env:RESERVATION_COST_SCOPE) { $env:RESERVATION_COST_SCOPE } else { $null }
        totals       = $totals
        reservations = @($reservations)
        warnings     = @($warnings)
    } | ConvertTo-Json -Depth 8

    # ---------------------------------------------------------------------
    # 4. Refresh the cache, then answer
    # ---------------------------------------------------------------------
    if ($storageContext) {
        $tempFile = Join-Path ([IO.Path]::GetTempPath()) 'savings.json'
        try {
            $body | Out-File -FilePath $tempFile -Encoding utf8 -Force
            Set-AzStorageBlobContent -Context $storageContext `
                                     -Container $container `
                                     -Blob $cacheBlob `
                                     -File $tempFile `
                                     -Properties @{ ContentType = 'application/json' } `
                                     -Force | Out-Null
            Write-Host "Cache refreshed at $container/$cacheBlob."
        }
        catch {
            # A cache we cannot write is not a reason to fail the request.
            Write-Warning "Could not write the cache blob: $($_.Exception.Message)"
        }
        finally {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    Write-JsonResponse -StatusCode ([HttpStatusCode]::OK) -Body $body
}
catch {
    # -ErrorAction Continue is load-bearing: this script runs with
    # $ErrorActionPreference = 'Stop', under which Write-Error is itself
    # terminating and would abandon the response below - leaving the caller
    # with a bare host 500 and none of the diagnostic.
    Write-Error "Reservation savings collection failed: $($_.Exception.Message)" -ErrorAction Continue
    Write-JsonResponse -StatusCode ([HttpStatusCode]::InternalServerError) `
                       -Body (@{ error = $_.Exception.Message } | ConvertTo-Json)
}
