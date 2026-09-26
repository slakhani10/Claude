/**
 * Bundled demo snapshot used when INVENTORY_CONFIG.apiUrl is empty.
 * Shape matches the GetInventory function's response exactly.
 */
window.SAMPLE_INVENTORY = {
  generatedAt: new Date().toISOString(),
  regions: [
    { region: "northcentralus",        collectedAt: new Date(Date.now() - 4 * 60000).toISOString(),  serverCount: 5 },
    { region: "northeurope",    collectedAt: new Date(Date.now() - 7 * 60000).toISOString(),  serverCount: 4 },
    { region: "southeastasia", collectedAt: new Date(Date.now() - 11 * 60000).toISOString(), serverCount: 3 },
  ],
  servers: [
    {
      name: "APP-NCU-01", region: "northcentralus", resourceGroup: "rg-apps-ncu", ipAddress: "10.10.1.4",
      osCaption: "Microsoft Windows Server 2019 Standard", osVersion: "10.0.17763", osBuild: "17763",
      cores: 4, logicalProcessors: 8, memoryGB: 16, domain: "corp.contoso.com",
      sql: { installed: false, instances: [] }, collectionError: null,
    },
    {
      name: "SQL-NCU-01", region: "northcentralus", resourceGroup: "rg-data-ncu", ipAddress: "10.10.2.10",
      osCaption: "Microsoft Windows Server 2016 Datacenter", osVersion: "10.0.14393", osBuild: "14393",
      cores: 8, logicalProcessors: 16, memoryGB: 64, domain: "corp.contoso.com",
      sql: {
        installed: true,
        instances: [
          { instance: "MSSQLSERVER", serviceState: "Running", edition: "Enterprise Edition: Core-based Licensing", version: "13.0.6455.2", baseVersion: "13.0.6455.2" },
        ],
      },
      collectionError: null,
    },
    {
      name: "LEGACY-NCU-02", region: "northcentralus", resourceGroup: "rg-legacy-ncu", ipAddress: "10.10.3.21",
      osCaption: "Microsoft Windows Server 2008 R2 Enterprise", osVersion: "6.1.7601", osBuild: "7601",
      cores: 2, logicalProcessors: 4, memoryGB: 8, domain: "corp.contoso.com",
      sql: {
        installed: true,
        instances: [
          { instance: "MSSQLSERVER", serviceState: "Running", edition: "Standard Edition", version: "10.50.6560.0", baseVersion: "10.50.6560.0" },
        ],
      },
      collectionError: null,
    },
    {
      name: "WEB-NCU-03", region: "northcentralus", resourceGroup: "rg-apps-ncu", ipAddress: "10.10.1.7",
      osCaption: "Microsoft Windows Server 2022 Datacenter Azure Edition", osVersion: "10.0.20348", osBuild: "20348",
      cores: 4, logicalProcessors: 8, memoryGB: 16, domain: "corp.contoso.com",
      sql: { installed: false, instances: [] }, collectionError: null,
    },
    {
      name: "FILE-NCU-04", region: "northcentralus", resourceGroup: "rg-infra-ncu", ipAddress: "10.10.4.5",
      osCaption: null, osVersion: null, osBuild: null,
      cores: null, logicalProcessors: null, memoryGB: null, domain: null,
      sql: { installed: false, instances: [] },
      collectionError: "WinRM cannot complete the operation: connection timed out",
    },
    {
      name: "ERP-NEU-01", region: "northeurope", resourceGroup: "rg-erp-neu", ipAddress: "10.20.1.4",
      osCaption: "Microsoft Windows Server 2012 R2 Standard", osVersion: "6.3.9600", osBuild: "9600",
      cores: 8, logicalProcessors: 16, memoryGB: 32, domain: "corp.contoso.com",
      sql: {
        installed: true,
        instances: [
          { instance: "ERP", serviceState: "Running", edition: "Enterprise Edition", version: "11.0.7507.2", baseVersion: "11.0.7507.2" },
        ],
      },
      collectionError: null,
    },
    {
      name: "SQL-NEU-02", region: "northeurope", resourceGroup: "rg-data-neu", ipAddress: "10.20.2.8",
      osCaption: "Microsoft Windows Server 2022 Datacenter", osVersion: "10.0.20348", osBuild: "20348",
      cores: 16, logicalProcessors: 32, memoryGB: 128, domain: "corp.contoso.com",
      sql: {
        installed: true,
        instances: [
          { instance: "MSSQLSERVER", serviceState: "Running", edition: "Enterprise Edition: Core-based Licensing", version: "16.0.4135.4", baseVersion: "16.0.4135.4" },
          { instance: "REPORTING", serviceState: "Running", edition: "Standard Edition", version: "15.0.4382.1", baseVersion: "15.0.4382.1" },
        ],
      },
      collectionError: null,
    },
    {
      name: "APP-NEU-03", region: "northeurope", resourceGroup: "rg-apps-neu", ipAddress: "10.20.1.9",
      osCaption: "Microsoft Windows Server 2016 Standard", osVersion: "10.0.14393", osBuild: "14393",
      cores: 4, logicalProcessors: 8, memoryGB: 16, domain: "corp.contoso.com",
      sql: { installed: false, instances: [] }, collectionError: null,
    },
    {
      name: "DC-NEU-01", region: "northeurope", resourceGroup: "rg-identity-neu", ipAddress: "10.20.5.4",
      osCaption: "Microsoft Windows Server 2019 Datacenter", osVersion: "10.0.17763", osBuild: "17763",
      cores: 2, logicalProcessors: 4, memoryGB: 8, domain: "corp.contoso.com",
      sql: { installed: false, instances: [] }, collectionError: null,
    },
    {
      name: "BATCH-SEA-01", region: "southeastasia", resourceGroup: "rg-batch-sea", ipAddress: "10.30.1.4",
      osCaption: "Microsoft Windows Server 2012 Standard", osVersion: "6.2.9200", osBuild: "9200",
      cores: 4, logicalProcessors: 8, memoryGB: 16, domain: "corp.contoso.com",
      sql: {
        installed: true,
        instances: [
          { instance: "BATCH", serviceState: "Stopped", edition: "Express Edition", version: "12.0.6449.1", baseVersion: "12.0.6449.1" },
        ],
      },
      collectionError: null,
    },
    {
      name: "APP-SEA-02", region: "southeastasia", resourceGroup: "rg-apps-sea", ipAddress: "10.30.2.6",
      osCaption: "Microsoft Windows Server 2019 Standard", osVersion: "10.0.17763", osBuild: "17763",
      cores: 4, logicalProcessors: 8, memoryGB: 16, domain: "corp.contoso.com",
      sql: {
        installed: true,
        instances: [
          { instance: "MSSQLSERVER", serviceState: "Running", edition: "Developer Edition", version: "14.0.3465.1", baseVersion: "14.0.3465.1" },
        ],
      },
      collectionError: null,
    },
    {
      name: "SQL-SEA-03", region: "southeastasia", resourceGroup: "rg-data-sea", ipAddress: "10.30.3.11",
      osCaption: "Microsoft Windows Server 2025 Datacenter", osVersion: "10.0.26100", osBuild: "26100",
      cores: 8, logicalProcessors: 16, memoryGB: 64, domain: "corp.contoso.com",
      sql: {
        installed: true,
        instances: [
          { instance: "MSSQLSERVER", serviceState: "Running", edition: "Standard Edition", version: "16.0.4140.3", baseVersion: "16.0.4140.3" },
        ],
      },
      collectionError: null,
    },
  ],
};

/**
 * Bundled demo reservations, used when reservationsApiUrl is empty.
 * Shape matches the GetReservationSavings function's response exactly.
 *
 * Deliberately a mixed bag, so the demo shows every state the view renders:
 * a well-used reservation, an under-used one, one that costs more than the
 * usage it covers, a non-VM type with no comparable retail meter, and rows
 * costed from each of the three cost sources.
 */
const resMonth = (() => {
  const date = new Date();
  date.setUTCMonth(date.getUTCMonth() - 1);
  return date.toISOString().slice(0, 7);
})();
const resInMonths = (months) => {
  const date = new Date();
  date.setUTCMonth(date.getUTCMonth() + months);
  return date.toISOString();
};

window.SAMPLE_RESERVATIONS = {
  generatedAt: new Date().toISOString(),
  currency: "USD",
  costMonth: resMonth,
  costScope: null,
  totals: {
    count: 6,
    monthlyCost: 9227.62,
    payGoMonthlyCost: 13181.28,
    monthlySaving: 3953.66,
    annualSaving: 47443.92,
    remainingTermSaving: 67506.4,
    realizedMonthlySaving: 1758.98,
    savingPercent: 30.0,
    underutilizedCount: 2,
  },
  reservations: [
    {
      name: "prod-d4sv3-ncus", resourceType: "VirtualMachines", sku: "Standard_D4s_v3",
      region: "northcentralus", quantity: 20, term: "P3Y", billingPlan: "Monthly",
      state: "Succeeded", scope: "Shared", instanceFlexibility: "On", autoRenew: true,
      effectiveDate: resInMonths(-18), expiryDate: resInMonths(18), monthsRemaining: 18,
      monthlyCost: 1902.4, payGoHourlyRate: 0.192, payGoMonthlyCost: 2803.2,
      monthlySaving: 900.8, savingPercent: 32.1, annualSaving: 10809.6,
      remainingTermSaving: 16214.4, utilizationPercent: 98.4,
      realizedMonthlySaving: 856.95, costSource: "CostManagement",
      reservationOrderId: "aaaaaaaa-1111-2222-3333-000000000001",
      reservationId: "bbbbbbbb-1111-2222-3333-000000000001", notes: null,
    },
    {
      name: "prod-e16sv5-neu", resourceType: "VirtualMachines", sku: "Standard_E16s_v5",
      region: "northeurope", quantity: 8, term: "P3Y", billingPlan: "Upfront",
      state: "Succeeded", scope: "Shared", instanceFlexibility: "On", autoRenew: true,
      effectiveDate: resInMonths(-8), expiryDate: resInMonths(28), monthsRemaining: 28,
      monthlyCost: 3271.11, payGoHourlyRate: 1.008, payGoMonthlyCost: 5886.72,
      monthlySaving: 2615.61, savingPercent: 44.4, annualSaving: 31387.32,
      remainingTermSaving: 73237.08, utilizationPercent: 96.1,
      realizedMonthlySaving: 2384.62, costSource: "CostManagement",
      reservationOrderId: "aaaaaaaa-1111-2222-3333-000000000002",
      reservationId: "bbbbbbbb-1111-2222-3333-000000000002", notes: null,
    },
    {
      name: "dev-d8sv4-sea", resourceType: "VirtualMachines", sku: "Standard_D8s_v4",
      region: "southeastasia", quantity: 6, term: "P1Y", billingPlan: "Upfront",
      state: "Succeeded", scope: "Single", instanceFlexibility: "On", autoRenew: false,
      effectiveDate: resInMonths(-9), expiryDate: resInMonths(3), monthsRemaining: 3,
      monthlyCost: 1341.67, payGoHourlyRate: 0.384, payGoMonthlyCost: 1681.92,
      monthlySaving: 340.25, savingPercent: 20.2, annualSaving: 4083.0,
      remainingTermSaving: 1020.75, utilizationPercent: 41.3,
      realizedMonthlySaving: -647.02, costSource: "Retail",
      reservationOrderId: "aaaaaaaa-1111-2222-3333-000000000003",
      reservationId: "bbbbbbbb-1111-2222-3333-000000000003",
      notes: "List price - excludes any negotiated discount",
    },
    {
      name: "test-b2ms-ncus", resourceType: "VirtualMachines", sku: "Standard_B2ms",
      region: "northcentralus", quantity: 10, term: "P1Y", billingPlan: "Monthly",
      state: "Succeeded", scope: "Single", instanceFlexibility: "On", autoRenew: false,
      effectiveDate: resInMonths(-2), expiryDate: resInMonths(10), monthsRemaining: 10,
      monthlyCost: 468.0, payGoHourlyRate: 0.0832, payGoMonthlyCost: 607.36,
      monthlySaving: 139.36, savingPercent: 22.9, annualSaving: 1672.32,
      remainingTermSaving: 1393.6, utilizationPercent: 72.5,
      realizedMonthlySaving: -27.66, costSource: "BillingPlan",
      reservationOrderId: "aaaaaaaa-1111-2222-3333-000000000004",
      reservationId: "bbbbbbbb-1111-2222-3333-000000000004", notes: null,
    },
    {
      name: "sql-mi-gp-neu", resourceType: "SqlDatabases", sku: "SQLDB_GP_Gen5",
      region: "northeurope", quantity: 16, term: "P1Y", billingPlan: "Upfront",
      state: "Succeeded", scope: "Shared", instanceFlexibility: null, autoRenew: true,
      effectiveDate: resInMonths(-5), expiryDate: resInMonths(7), monthsRemaining: 7,
      monthlyCost: 1892.0, payGoHourlyRate: null, payGoMonthlyCost: null,
      monthlySaving: null, savingPercent: null, annualSaving: null,
      remainingTermSaving: null, utilizationPercent: 99.2,
      realizedMonthlySaving: null, costSource: "BillingPlan",
      reservationOrderId: "aaaaaaaa-1111-2222-3333-000000000005",
      reservationId: "bbbbbbbb-1111-2222-3333-000000000005",
      notes: "No public pay-as-you-go meter matched SKU 'SQLDB_GP_Gen5' in 'northeurope'",
    },
    {
      name: "cosmos-ru-shared", resourceType: "CosmosDb", sku: "CosmosDBReservedCapacity",
      region: null, quantity: 100, term: "P1Y", billingPlan: "Upfront",
      state: "Succeeded", scope: "Shared", instanceFlexibility: null, autoRenew: false,
      effectiveDate: resInMonths(-11), expiryDate: resInMonths(1), monthsRemaining: 1,
      monthlyCost: 352.44, payGoHourlyRate: null, payGoMonthlyCost: null,
      monthlySaving: null, savingPercent: null, annualSaving: null,
      remainingTermSaving: null, utilizationPercent: null,
      realizedMonthlySaving: null, costSource: "BillingPlan",
      reservationOrderId: "aaaaaaaa-1111-2222-3333-000000000006",
      reservationId: "bbbbbbbb-1111-2222-3333-000000000006",
      notes: "No public pay-as-you-go meter matched SKU 'CosmosDBReservedCapacity' in ''",
    },
  ],
  warnings: [
    "Demo data. Cost Management could not break cost down by reservation on scope '/subscriptions/<id>'; some rows fall back to public list prices.",
  ],
};
