<#
.SYNOPSIS
    Reports the monthly cost and projected savings of every active Azure
    reservation the signed-in identity can see.

.DESCRIPTION
    Dot-source this file to get two functions:

      Get-AzReservationSavings   emits one object per active reservation
      Show-AzReservationSavings  renders those objects as a table with totals

    For each reservation the report answers three questions:

      1. What does this reservation cost me per month?
      2. What would the same capacity cost at pay-as-you-go rates?
      3. What is the difference - the saving - per month, per year, and over
         the reservation's remaining term?

    Monthly cost is resolved from the best source available (see -CostSource):

      CostManagement  Actual amortized cost billed last complete month,
                      grouped by ReservationId. Most accurate - it reflects
                      your negotiated prices - but the ReservationId dimension
                      needs an EA or MCA billing scope.
      BillingPlan     For reservations bought on the "monthly payments" plan,
                      the real recurring payment from the reservation order's
                      plan information.
      Retail          Public list price for the reservation term from the
                      Azure Retail Prices API, divided across the term.
                      Always available, but list price - it ignores any
                      discount you negotiated.

    Pay-as-you-go comparison rates always come from the Azure Retail Prices
    API (public, unauthenticated). For virtual machines the base compute rate
    is used - Linux, non-Spot - because a reservation discounts compute only,
    never the Windows or SQL licence riding on top of it.

    Utilization comes back on the reservation itself, so the report also shows
    what you are *realizing*: a 40%-utilized reservation only earns 40% of the
    pay-as-you-go capacity it paid for, and RealizedMonthlySaving goes negative
    when a reservation is costing more than the usage it covers.

.NOTES
    Permissions
      - Reservation Reader on the reservation order (or Owner/Reader inherited
        from the billing account) to list reservations.
      - Cost Management Reader on the billing scope for the CostManagement
        cost source.
      Nothing here writes; every call is a read.

    Modules
      Az.Accounts only. Reservation, Cost Management and retail pricing calls
      go over REST, so the report does not drift when the Az.Reservations
      cmdlet surface changes between major versions.

.EXAMPLE
    . ./scripts/Get-AzReservationSavings.ps1
    Show-AzReservationSavings

    Prints the table and the portfolio totals.

.EXAMPLE
    Get-AzReservationSavings | Sort-Object MonthlySaving | Select-Object -First 10

    The ten reservations returning the least - your renewal review list.

.EXAMPLE
    Get-AzReservationSavings -CostScope '/providers/Microsoft.Billing/billingAccounts/1234567' |
        Export-Csv ./reservation-savings.csv -NoTypeInformation

    Bills the whole enrollment through Cost Management and exports the result.

.EXAMPLE
    Get-AzReservationSavings -CostSource Retail -Currency EUR

    Skips Cost Management entirely and prices everything at public list rates
    in euros - useful before you have billing-scope access.
#>

#Requires -Version 7.0
#Requires -Modules Az.Accounts

$script:ReservationApiVersion  = '2022-11-01'
$script:CostManagementApiVersion = '2023-03-01'
$script:RetailPricesApiVersion = '2023-01-01-preview'
$script:RetailPriceCache       = @{}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Reservation payloads have moved property names across API versions (and
# expiryDate vs expiryDateTime co-exist in the same version), so read through
# a list of candidates rather than binding to one spelling.
function Get-FirstValue {
    param($InputObject, [string[]]$Name)

    foreach ($candidate in $Name) {
        if ($null -eq $InputObject) { continue }
        $property = $InputObject.PSObject.Properties[$candidate]
        if ($property -and $null -ne $property.Value -and "$($property.Value)" -ne '') {
            return $property.Value
        }
    }
    return $null
}

function Invoke-ArmCollection {
    param(
        [Parameter(Mandatory)][string]$Uri
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next  = if ($Uri -match '^https?://') { $Uri } else { "https://management.azure.com$Uri" }

    while ($next) {
        $response = Invoke-AzRestMethod -Method GET -Uri $next
        if ($response.StatusCode -ge 400) {
            throw "GET $next returned $($response.StatusCode): $($response.Content)"
        }
        $payload = $response.Content | ConvertFrom-Json -Depth 20
        if ($payload.PSObject.Properties['value'] -and $payload.value) {
            $items.AddRange([object[]]$payload.value)
        }
        $next = Get-FirstValue -InputObject $payload -Name 'nextLink', '@odata.nextLink'
    }

    , $items.ToArray()
}

function Invoke-ArmObject {
    param([Parameter(Mandatory)][string]$Uri)

    $absolute = if ($Uri -match '^https?://') { $Uri } else { "https://management.azure.com$Uri" }
    $response = Invoke-AzRestMethod -Method GET -Uri $absolute
    if ($response.StatusCode -ge 400) {
        throw "GET $absolute returned $($response.StatusCode): $($response.Content)"
    }
    $response.Content | ConvertFrom-Json -Depth 20
}

# One retail query per SKU+region returns both the pay-as-you-go meters and the
# reservation meters, so cache on that pair and slice the result twice.
function Get-RetailPrice {
    param(
        [Parameter(Mandatory)][string]$Filter,
        [string]$Currency = 'USD'
    )

    $cacheKey = "$Currency|$Filter"
    if ($script:RetailPriceCache.ContainsKey($cacheKey)) {
        return $script:RetailPriceCache[$cacheKey]
    }

    $items = [System.Collections.Generic.List[object]]::new()
    $uri = 'https://prices.azure.com/api/retail/prices' +
           "?api-version=$script:RetailPricesApiVersion" +
           "&currencyCode='$Currency'" +
           "&`$filter=$([uri]::EscapeDataString($Filter))"

    while ($uri) {
        $page = Invoke-RestMethod -Method GET -Uri $uri -ErrorAction Stop
        if ($page.PSObject.Properties['Items'] -and $page.Items) {
            $items.AddRange([object[]]$page.Items)
        }
        $uri = $page.NextPageLink
    }

    $result = $items.ToArray()
    $script:RetailPriceCache[$cacheKey] = $result
    return $result
}

function Get-RoundedAmount {
    param($Value, [int]$Digits = 2)

    if ($null -eq $Value) { return $null }
    return [math]::Round([double]$Value, $Digits)
}

function ConvertFrom-ReservationTerm {
    param([string]$Term)

    switch -Regex ($Term) {
        '^P(\d+)Y$' {
            $years = [int]$Matches[1]
            return [pscustomobject]@{
                Months     = $years * 12
                RetailName = if ($years -eq 1) { '1 Year' } else { "$years Years" }
            }
        }
        '^P(\d+)M$' {
            $months = [int]$Matches[1]
            return [pscustomobject]@{
                Months     = $months
                RetailName = "$months Months"
            }
        }
        default {
            return [pscustomobject]@{ Months = $null; RetailName = $null }
        }
    }
}

# Amortized cost for one calendar month, grouped by reservation. Returns a
# lookup keyed on the reservation GUID (Cost Management sometimes returns the
# bare GUID and sometimes the full resource id - both normalize to the same
# key). Returns $null when the scope cannot answer, so callers fall back.
function Get-AmortizedReservationCost {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][datetime]$MonthStart,
        [Parameter(Mandatory)][datetime]$MonthEnd,
        [string]$Currency = 'USD'
    )

    $costColumn = if ($Currency -eq 'USD') { 'CostUSD' } else { 'Cost' }
    $body = @{
        type       = 'AmortizedCost'
        timeframe  = 'Custom'
        timePeriod = @{
            from = $MonthStart.ToString('yyyy-MM-ddTHH:mm:ssZ')
            to   = $MonthEnd.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        dataset    = @{
            granularity = 'None'
            aggregation = @{ totalCost = @{ name = $costColumn; function = 'Sum' } }
            grouping    = @(@{ type = 'Dimension'; name = 'ReservationId' })
        }
    } | ConvertTo-Json -Depth 10

    $uri = "https://management.azure.com$($Scope.TrimEnd('/'))/providers/Microsoft.CostManagement/query" +
           "?api-version=$script:CostManagementApiVersion"

    $response = Invoke-AzRestMethod -Method POST -Uri $uri -Payload $body
    if ($response.StatusCode -ge 400) {
        Write-Verbose "Cost Management query on '$Scope' returned $($response.StatusCode): $($response.Content)"
        return $null
    }

    $payload = $response.Content | ConvertFrom-Json -Depth 20
    $columns = @($payload.properties.columns.name)
    $costIndex        = $columns.IndexOf($costColumn)
    $reservationIndex = $columns.IndexOf('ReservationId')
    if ($costIndex -lt 0 -or $reservationIndex -lt 0) {
        Write-Verbose "Cost Management response on '$Scope' did not include the expected columns."
        return $null
    }

    $lookup = @{}
    foreach ($row in $payload.properties.rows) {
        $rawId = "$($row[$reservationIndex])"
        if (-not $rawId) { continue }
        $key = ($rawId -split '/')[-1].ToLowerInvariant()
        $lookup[$key] = [double]$row[$costIndex] + ($lookup[$key] ?? 0)
    }
    return $lookup
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

function Get-AzReservationSavings {
    <#
    .SYNOPSIS
        Emits one object per active Azure reservation with its monthly cost,
        the pay-as-you-go cost of the same capacity, and the saving between them.

    .PARAMETER ReservationOrderId
        Limit the report to these reservation order ids (GUIDs). Default: every
        order the signed-in identity can read.

    .PARAMETER CostSource
        Where the monthly cost comes from. 'Auto' (default) tries Cost
        Management, then the monthly billing plan, then retail list price, and
        records the winner on each row's CostSource property.

    .PARAMETER CostScope
        Billing scope for the Cost Management query, e.g.
        '/providers/Microsoft.Billing/billingAccounts/1234567' or
        '/subscriptions/<guid>'. Defaults to the current context's
        subscription. A billing account scope covers reservations that are
        shared across subscriptions; a subscription scope only sees its own
        share of them.

    .PARAMETER CostMonth
        Any date inside the month to bill for. Defaults to the last complete
        calendar month, because the current month is always partial.

    .PARAMETER Currency
        ISO currency code for retail prices, e.g. USD, EUR, GBP. Default USD.

    .PARAMETER HoursPerMonth
        Hours used to convert hourly pay-as-you-go rates to a month. Default
        730 - Azure's own convention for a month of capacity.

    .PARAMETER IncludeExpired
        Also report reservations that are expired or not in a succeeded state.

    .PARAMETER SkipUtilization
        Do not read utilization aggregates, and omit the realized-saving
        columns. Slightly faster and avoids a permission surface.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]]$ReservationOrderId,

        [ValidateSet('Auto', 'CostManagement', 'BillingPlan', 'Retail')]
        [string]$CostSource = 'Auto',

        [string]$CostScope,

        [datetime]$CostMonth,

        [ValidatePattern('^[A-Za-z]{3}$')]
        [string]$Currency = 'USD',

        [ValidateRange(1, 744)]
        [double]$HoursPerMonth = 730,

        [switch]$IncludeExpired,

        [switch]$SkipUtilization
    )

    $ErrorActionPreference = 'Stop'

    $context = Get-AzContext
    if (-not $context) {
        throw 'No Azure context. Run Connect-AzAccount first.'
    }

    # --- The month to bill -------------------------------------------------
    if (-not $PSBoundParameters.ContainsKey('CostMonth')) {
        $CostMonth = (Get-Date).ToUniversalTime().AddMonths(-1)
    }
    $monthStart = [datetime]::new($CostMonth.Year, $CostMonth.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $monthEnd   = $monthStart.AddMonths(1).AddSeconds(-1)

    # --- 1. Every reservation this identity can see ------------------------
    Write-Verbose 'Listing reservations.'
    $reservations = Invoke-ArmCollection -Uri (
        "/providers/Microsoft.Capacity/reservations?api-version=$script:ReservationApiVersion")

    if ($ReservationOrderId) {
        $wanted = @{}
        foreach ($id in $ReservationOrderId) { $wanted[$id.Trim().ToLowerInvariant()] = $true }
        $reservations = @($reservations | Where-Object {
            $orderId = ($_.id -split '/')[-3]
            $wanted.ContainsKey($orderId.ToLowerInvariant())
        })
    }

    $now = (Get-Date).ToUniversalTime()
    if (-not $IncludeExpired) {
        $reservations = @($reservations | Where-Object {
            $state  = Get-FirstValue -InputObject $_.properties -Name 'provisioningState', 'displayProvisioningState'
            $expiry = Get-FirstValue -InputObject $_.properties -Name 'expiryDateTime', 'expiryDate'
            ($state -eq 'Succeeded') -and (-not $expiry -or ([datetime]$expiry) -gt $now)
        })
    }

    if (-not $reservations -or $reservations.Count -eq 0) {
        Write-Warning 'No matching reservations found. Check that the signed-in identity has Reservation Reader on the reservation orders.'
        return
    }
    Write-Verbose "Found $($reservations.Count) reservation(s) to report."

    # --- 2. Actual amortized cost, if the scope will answer ----------------
    $amortized = $null
    if ($CostSource -in 'Auto', 'CostManagement') {
        if (-not $CostScope) { $CostScope = "/subscriptions/$($context.Subscription.Id)" }
        Write-Verbose "Querying amortized cost on '$CostScope' for $($monthStart.ToString('yyyy-MM'))."
        try {
            $amortized = Get-AmortizedReservationCost -Scope $CostScope -MonthStart $monthStart `
                                                      -MonthEnd $monthEnd -Currency $Currency
        }
        catch {
            Write-Verbose "Cost Management query failed: $($_.Exception.Message)"
            $amortized = $null
        }
        if ($null -eq $amortized -and $CostSource -eq 'CostManagement') {
            throw "Cost Management returned no reservation cost for scope '$CostScope'. " +
                  'Grant Cost Management Reader on an EA or MCA billing scope, or use -CostSource Auto.'
        }
        if ($null -eq $amortized) {
            Write-Warning "Cost Management could not break cost down by reservation on scope '$CostScope'; falling back to billing plan and list prices."
        }
    }

    $orderCache = @{}

    foreach ($reservation in $reservations) {
        $properties  = $reservation.properties
        $orderId     = ($reservation.id -split '/')[-3]
        $reservationGuid = ($reservation.id -split '/')[-1]

        $sku          = Get-FirstValue -InputObject $reservation.sku -Name 'name'
        $region       = Get-FirstValue -InputObject $reservation -Name 'location'
        $quantity     = [double](Get-FirstValue -InputObject $properties -Name 'quantity')
        if (-not $quantity) { $quantity = 1 }
        $resourceType = Get-FirstValue -InputObject $properties -Name 'reservedResourceType'
        $termCode     = Get-FirstValue -InputObject $properties -Name 'term'
        $term         = ConvertFrom-ReservationTerm -Term $termCode
        $expiry       = Get-FirstValue -InputObject $properties -Name 'expiryDateTime', 'expiryDate'
        $effective    = Get-FirstValue -InputObject $properties -Name 'effectiveDateTime', 'purchaseDateTime'
        $billingPlan  = Get-FirstValue -InputObject $properties -Name 'billingPlan'

        $monthsRemaining = if ($expiry) {
            [math]::Max(0, [math]::Round((([datetime]$expiry) - $now).TotalDays / 30.44, 1))
        } else { $null }

        $notes = [System.Collections.Generic.List[string]]::new()

        # --- Reservation order: exact payment on the monthly billing plan ---
        if (-not $orderCache.ContainsKey($orderId)) {
            try {
                $orderCache[$orderId] = Invoke-ArmObject -Uri (
                    "/providers/Microsoft.Capacity/reservationOrders/$orderId" +
                    "?api-version=$script:ReservationApiVersion")
            }
            catch {
                Write-Verbose "Could not read reservation order '$orderId': $($_.Exception.Message)"
                $orderCache[$orderId] = $null
            }
        }
        $order = $orderCache[$orderId]
        if (-not $billingPlan -and $order) {
            $billingPlan = Get-FirstValue -InputObject $order.properties -Name 'billingPlan'
        }

        # The order is billed as a whole; split its payment across the
        # reservations inside it in proportion to quantity.
        $planMonthlyCost = $null
        if ($order) {
            $planInformation = Get-FirstValue -InputObject $order.properties -Name 'planInformation'
            if ($planInformation) {
                # Each transaction is one payment; the most recent one that was
                # actually taken is the current recurring amount.
                $payment = $null
                $transactions = Get-FirstValue -InputObject $planInformation -Name 'transactions'
                if ($transactions) {
                    $paid = @($transactions | Where-Object { $_.status -notin 'Cancelled', 'Failed' })
                    if ($paid.Count -gt 0) {
                        $payment = Get-FirstValue -InputObject $paid[-1].pricingCurrencyTotal -Name 'amount'
                    }
                }
                if ($null -eq $payment) {
                    $payment = Get-FirstValue -InputObject $planInformation.pricingCurrencyTotal -Name 'amount'
                }
                if ($null -ne $payment) {
                    $orderQuantity = [double](Get-FirstValue -InputObject $order.properties -Name 'originalQuantity')
                    $share = if ($orderQuantity -gt 0) { $quantity / $orderQuantity } else { 1 }
                    $planMonthlyCost = [double]$payment * $share
                }
            }
        }

        # --- Retail prices: pay-as-you-go rate and list reservation price ---
        $paygHourly       = $null
        $retailMonthlyCost = $null
        if ($sku -and $region) {
            try {
                $prices = Get-RetailPrice -Currency $Currency -Filter (
                    "armRegionName eq '$region' and armSkuName eq '$sku'")

                # A reservation discounts compute only, so compare against the
                # base rate: Linux, non-Spot, no licence riding on top.
                $baseRates = @($prices | Where-Object {
                    $_.retailPrice -gt 0 -and
                    $_.skuName -notmatch 'Spot|Low Priority' -and
                    $_.productName -notmatch 'Windows'
                })

                $paygMeter = $baseRates |
                    Where-Object { $_.type -eq 'Consumption' -and $_.unitOfMeasure -match '1 Hour' } |
                    Sort-Object retailPrice | Select-Object -First 1
                if ($paygMeter) { $paygHourly = [double]$paygMeter.retailPrice }

                if ($term.RetailName) {
                    $reservationMeter = $baseRates |
                        Where-Object { $_.type -eq 'Reservation' -and $_.reservationTerm -eq $term.RetailName } |
                        Sort-Object retailPrice | Select-Object -First 1
                    # For reservation meters the retail API reports the whole
                    # term's price per unit, despite saying "1 Hour".
                    if ($reservationMeter -and $term.Months) {
                        $retailMonthlyCost = ([double]$reservationMeter.retailPrice / $term.Months) * $quantity
                    }
                }
            }
            catch {
                Write-Verbose "Retail price lookup failed for '$sku' in '$region': $($_.Exception.Message)"
                $notes.Add('Retail price lookup failed')
            }
        }
        if ($null -eq $paygHourly) {
            $notes.Add("No public pay-as-you-go meter matched SKU '$sku' in '$region'")
        }

        # --- Settle on a monthly cost --------------------------------------
        $monthlyCost   = $null
        $resolvedSource = $null
        $costCandidates = switch ($CostSource) {
            'Auto'           { @('CostManagement', 'BillingPlan', 'Retail') }
            default          { @($CostSource) }
        }
        foreach ($candidate in $costCandidates) {
            switch ($candidate) {
                'CostManagement' {
                    if ($amortized) {
                        foreach ($key in @($reservationGuid, $orderId)) {
                            $lookupKey = $key.ToLowerInvariant()
                            if ($amortized.ContainsKey($lookupKey)) {
                                $monthlyCost = $amortized[$lookupKey]
                                $resolvedSource = 'CostManagement'
                                break
                            }
                        }
                    }
                }
                'BillingPlan' {
                    if ($null -ne $planMonthlyCost) {
                        $monthlyCost = $planMonthlyCost
                        $resolvedSource = 'BillingPlan'
                    }
                }
                'Retail' {
                    if ($null -ne $retailMonthlyCost) {
                        $monthlyCost = $retailMonthlyCost
                        $resolvedSource = 'Retail'
                    }
                }
            }
            if ($null -ne $monthlyCost) { break }
        }
        if ($null -eq $monthlyCost) {
            $notes.Add('Monthly cost could not be resolved from any source')
        }
        elseif ($resolvedSource -eq 'Retail') {
            $notes.Add('List price - excludes any negotiated discount')
        }

        # A reservation that costs more than pay-as-you-go is either genuinely
        # a bad buy or a mismatched meter - either way it deserves a flag
        # rather than a silently negative saving.
        if ($null -ne $monthlyCost -and $null -ne $paygHourly -and
            $monthlyCost -gt ($paygHourly * $HoursPerMonth * $quantity)) {
            $notes.Add('Costs more than pay-as-you-go - verify the matched meter')
        }

        # --- Savings --------------------------------------------------------
        $paygMonthly = if ($null -ne $paygHourly) { $paygHourly * $HoursPerMonth * $quantity } else { $null }
        $monthlySaving = if ($null -ne $paygMonthly -and $null -ne $monthlyCost) {
            $paygMonthly - $monthlyCost
        } else { $null }
        $savingPercent = if ($monthlySaving -and $paygMonthly -gt 0) {
            [math]::Round(($monthlySaving / $paygMonthly) * 100, 1)
        } else { $null }
        $annualSaving = if ($null -ne $monthlySaving) { $monthlySaving * 12 } else { $null }
        $remainingTermSaving = if ($null -ne $monthlySaving -and $null -ne $monthsRemaining) {
            $monthlySaving * $monthsRemaining
        } else { $null }

        # --- Utilization: how much of that saving is actually realized ------
        $utilization = $null
        if (-not $SkipUtilization) {
            $aggregates = Get-FirstValue -InputObject (
                Get-FirstValue -InputObject $properties -Name 'utilization') -Name 'aggregates'
            if ($aggregates) {
                # Prefer the widest window on offer (usually 30 days).
                $widest = $aggregates | Sort-Object { [double]$_.grain } -Descending | Select-Object -First 1
                if ($widest) { $utilization = [math]::Round([double]$widest.value, 1) }
            }
        }
        $realizedSaving = if ($null -ne $utilization -and $null -ne $paygMonthly -and $null -ne $monthlyCost) {
            ($paygMonthly * ($utilization / 100)) - $monthlyCost
        } else { $null }

        [pscustomobject]@{
            PSTypeName             = 'Azure.ReservationSaving'
            Name                   = Get-FirstValue -InputObject $properties -Name 'displayName'
            ResourceType           = $resourceType
            Sku                    = $sku
            Region                 = $region
            Quantity               = $quantity
            Term                   = $termCode
            BillingPlan            = $billingPlan
            State                  = Get-FirstValue -InputObject $properties -Name 'provisioningState', 'displayProvisioningState'
            Scope                  = Get-FirstValue -InputObject $properties -Name 'userFriendlyAppliedScopeType', 'appliedScopeType'
            InstanceFlexibility    = Get-FirstValue -InputObject $properties -Name 'instanceFlexibility'
            AutoRenew              = Get-FirstValue -InputObject $properties -Name 'renew'
            EffectiveDate          = if ($effective) { [datetime]$effective } else { $null }
            ExpiryDate             = if ($expiry) { [datetime]$expiry } else { $null }
            MonthsRemaining        = $monthsRemaining
            Currency               = $Currency
            MonthlyCost            = Get-RoundedAmount $monthlyCost
            PayGoHourlyRate        = Get-RoundedAmount $paygHourly -Digits 5
            PayGoMonthlyCost       = Get-RoundedAmount $paygMonthly
            MonthlySaving          = Get-RoundedAmount $monthlySaving
            SavingPercent          = $savingPercent
            AnnualSaving           = Get-RoundedAmount $annualSaving
            RemainingTermSaving    = Get-RoundedAmount $remainingTermSaving
            UtilizationPercent     = $utilization
            RealizedMonthlySaving  = Get-RoundedAmount $realizedSaving
            CostSource             = $resolvedSource
            CostMonth              = $monthStart.ToString('yyyy-MM')
            ReservationOrderId     = $orderId
            ReservationId          = $reservationGuid
            Notes                  = if ($notes.Count) { $notes -join '; ' } else { $null }
        }
    }
}

function Show-AzReservationSavings {
    <#
    .SYNOPSIS
        Renders reservation savings as a table with portfolio totals.

    .PARAMETER Saving
        Objects from Get-AzReservationSavings. When omitted, this function
        calls Get-AzReservationSavings itself.

    .PARAMETER GetParameter
        Splatted through to Get-AzReservationSavings when -Saving is omitted,
        e.g. @{ CostScope = '/providers/Microsoft.Billing/billingAccounts/1234567' }.

    .EXAMPLE
        Show-AzReservationSavings

    .EXAMPLE
        Show-AzReservationSavings -GetParameter @{ Currency = 'GBP'; CostSource = 'Retail' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [pscustomobject[]]$Saving,

        [hashtable]$GetParameter = @{}
    )

    begin {
        $rows = [System.Collections.Generic.List[object]]::new()
    }
    process {
        if ($Saving) { $rows.AddRange($Saving) }
    }
    end {
        if ($rows.Count -eq 0) {
            $rows.AddRange(@(Get-AzReservationSavings @GetParameter))
        }
        if ($rows.Count -eq 0) { return }

        $currency = ($rows | Select-Object -First 1).Currency
        $money    = { param($value) if ($null -eq $value) { 'n/a' } else { '{0:N2}' -f $value } }

        # Hosts without a console (Azure Automation, a redirected pipe, CI)
        # report a width of -1, and Format-Table then renders nothing at all.
        $width = $Host.UI.RawUI.BufferSize.Width
        if (-not $width -or $width -lt 80) { $width = 220 }

        $table = $rows |
            Sort-Object -Property @{ Expression = 'MonthlySaving'; Descending = $true } |
            Format-Table -AutoSize -Property `
                @{ Name = 'Name';       Expression = { $_.Name } },
                @{ Name = 'Sku';        Expression = { $_.Sku } },
                @{ Name = 'Region';     Expression = { $_.Region } },
                @{ Name = 'Qty';        Expression = { '{0:N0}' -f $_.Quantity }; Align = 'Right' },
                @{ Name = 'Term';       Expression = { $_.Term } },
                @{ Name = "Cost/mo ($currency)";  Expression = { & $money $_.MonthlyCost }; Align = 'Right' },
                @{ Name = "PAYG/mo ($currency)";  Expression = { & $money $_.PayGoMonthlyCost }; Align = 'Right' },
                @{ Name = "Saving/mo ($currency)";Expression = { & $money $_.MonthlySaving }; Align = 'Right' },
                @{ Name = 'Saving %';   Expression = { if ($null -eq $_.SavingPercent) { 'n/a' } else { '{0:N1}' -f $_.SavingPercent } }; Align = 'Right' },
                @{ Name = 'Util %';     Expression = { if ($null -eq $_.UtilizationPercent) { '-' } else { '{0:N1}' -f $_.UtilizationPercent } }; Align = 'Right' },
                @{ Name = 'Mo left';    Expression = { $_.MonthsRemaining }; Align = 'Right' },
                @{ Name = 'Source';     Expression = { $_.CostSource } } |
            Out-String -Width $width
        Write-Host $table.TrimEnd()

        $totalCost      = ($rows | Measure-Object MonthlyCost -Sum).Sum
        $totalPayGo     = ($rows | Measure-Object PayGoMonthlyCost -Sum).Sum
        $totalSaving    = ($rows | Measure-Object MonthlySaving -Sum).Sum
        $totalRemaining = ($rows | Measure-Object RemainingTermSaving -Sum).Sum
        $totalRealized  = ($rows | Measure-Object RealizedMonthlySaving -Sum).Sum
        $percent        = if ($totalPayGo -gt 0) { ($totalSaving / $totalPayGo) * 100 } else { 0 }
        $costMonth      = ($rows | Select-Object -First 1).CostMonth

        Write-Host ''
        Write-Host "  $($rows.Count) active reservation(s), billed month $costMonth" -ForegroundColor Cyan
        Write-Host ("  {0,-34}{1,16}" -f 'Reservation cost / month',   (& $money $totalCost)   + " $currency")
        Write-Host ("  {0,-34}{1,16}" -f 'Pay-as-you-go equivalent',   (& $money $totalPayGo)  + " $currency")
        Write-Host ("  {0,-34}{1,16}" -f 'Projected saving / month',   (& $money $totalSaving) + " $currency") -ForegroundColor Green
        Write-Host ("  {0,-34}{1,16}" -f 'Projected saving / year',    (& $money ($totalSaving * 12)) + " $currency") -ForegroundColor Green
        Write-Host ("  {0,-34}{1,16}" -f 'Saving over remaining terms',(& $money $totalRemaining) + " $currency")
        Write-Host ("  {0,-34}{1,15:N1}%" -f 'Discount vs pay-as-you-go', $percent)
        if ($null -ne $totalRealized) {
            $realizedColour = if ($totalRealized -lt $totalSaving * 0.9) { 'Yellow' } else { 'Green' }
            Write-Host ("  {0,-34}{1,16}" -f 'Realized at current utilization', (& $money $totalRealized) + " $currency") -ForegroundColor $realizedColour
        }

        $underused = @($rows | Where-Object { $null -ne $_.UtilizationPercent -and $_.UtilizationPercent -lt 90 })
        if ($underused.Count) {
            Write-Host ''
            Write-Host "  $($underused.Count) reservation(s) below 90% utilization:" -ForegroundColor Yellow
            foreach ($row in $underused | Sort-Object UtilizationPercent) {
                Write-Host ("    {0,-40} {1,5:N1}%  realized saving {2} $currency" -f `
                    $row.Name, $row.UtilizationPercent, (& $money $row.RealizedMonthlySaving))
            }
        }

        $noted = @($rows | Where-Object Notes)
        if ($noted.Count) {
            Write-Host ''
            Write-Host '  Notes:' -ForegroundColor DarkGray
            foreach ($row in $noted) {
                Write-Host ("    {0,-40} {1}" -f $row.Name, $row.Notes) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
    }
}
