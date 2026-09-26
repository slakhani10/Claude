@{
    RootModule        = 'AzReservationSavings.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '9a2f4c1e-6b3d-4a58-9d27-5c0e8b1f7a34'
    Author            = 'Azure Server Inventory'
    Description       = 'Reports the monthly cost and projected savings of active Azure reservations.'
    PowerShellVersion = '7.0'

    # Az.Accounts is deliberately NOT a RequiredModule: in the function app it
    # arrives through managedDependency and is imported by profile.ps1, and
    # declaring it here would force a second import on every cold start.
    FunctionsToExport = @('Get-AzReservationSavings', 'Show-AzReservationSavings')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
