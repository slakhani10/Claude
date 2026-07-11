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
