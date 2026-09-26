<#
.SYNOPSIS
    Reports the monthly cost and projected savings of every active Azure
    reservation the signed-in identity can see.

.DESCRIPTION
    A console entry point for the AzReservationSavings module, which lives in
    functions/collector/Modules/ so the dashboard's HTTP endpoint and this
    script share one implementation.

    Dot-source this file to get both public functions:

      Get-AzReservationSavings   one object per active reservation, costed
      Show-AzReservationSavings  those objects as a table with totals

    See the module header for how monthly cost and savings are derived, and
    Get-Help Get-AzReservationSavings -Full for every parameter.

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

$modulePath = Join-Path $PSScriptRoot '../functions/collector/Modules/AzReservationSavings'
if (-not (Test-Path $modulePath)) {
    throw "Module not found at '$modulePath'. Run this script from a full checkout of the repository."
}

Import-Module $modulePath -Force -DisableNameChecking

Write-Verbose 'Get-AzReservationSavings and Show-AzReservationSavings are ready.'
