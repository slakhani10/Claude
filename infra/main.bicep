// Azure Server Inventory - infrastructure
//
// Deploys:
//   - ONE central storage account (the only cross-region data path; every
//     regional firewall must allow HTTPS 443 to this account, or you attach
//     a private endpoint for it inside each regional VNet)
//   - ONE PowerShell Function App PER REGION, VNet-integrated into that
//     region's subnet so it can reach servers over WMI/WinRM locally,
//     because region-to-region connectivity is blocked
//   - Role assignments so each app can write inventory blobs
//
// Elastic Premium (EP1) plans are used because regional VNet integration is
// required and is not available on the Consumption plan.

targetScope = 'resourceGroup'

@description('Prefix for all resource names, e.g. "srvinv".')
@maxLength(11)
param namePrefix string

@description('Region for the central storage account (pick your hub region).')
param hubLocation string = resourceGroup().location

@description('One entry per region to inventory: { name: "eastus", subnetId: "/subscriptions/.../subnets/snet-functions" }. The subnet must be delegated to Microsoft.Web/serverFarms.')
param regions array

@description('Windows account with remote WMI rights on the target servers (DOMAIN\\user or .\\localadmin).')
param wmiUsername string

@description('Password for the WMI account. Prefer replacing the app setting with a Key Vault reference after deployment.')
@secure()
param wmiPassword string

var storageName = toLower('${namePrefix}inv${uniqueString(resourceGroup().id)}')

// ---------------------------------------------------------------- storage
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: hubLocation
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource inventoryContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'inventory'
}

// ------------------------------------------------- per-region function apps
resource plans 'Microsoft.Web/serverfarms@2023-12-01' = [for region in regions: {
  name: '${namePrefix}-plan-${region.name}'
  location: region.name
  sku: { name: 'EP1', tier: 'ElasticPremium' }
  kind: 'elastic'
  properties: { maximumElasticWorkerCount: 3 }
}]

resource functionApps 'Microsoft.Web/sites@2023-12-01' = [for (region, i) in regions: {
  name: '${namePrefix}-func-${region.name}'
  location: region.name
  kind: 'functionapp'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plans[i].id
    httpsOnly: true
    virtualNetworkSubnetId: region.subnetId
    vnetRouteAllEnabled: true
    siteConfig: {
      powerShellVersion: '7.4'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'WEBSITE_CONTENTSHARE', value: toLower('${namePrefix}-func-${region.name}') }
        { name: 'INVENTORY_REGION', value: region.name }
        { name: 'INVENTORY_STORAGE_ACCOUNT', value: storage.name }
        { name: 'INVENTORY_CONTAINER', value: 'inventory' }
        { name: 'WMI_USERNAME', value: wmiUsername }
        { name: 'WMI_PASSWORD', value: wmiPassword }
      ]
    }
  }
}]

// Each app writes its region snapshot: Storage Blob Data Contributor
var blobContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource blobRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (region, i) in regions: {
  name: guid(storage.id, functionApps[i].name, blobContributorRoleId)
  scope: storage
  properties: {
    roleDefinitionId: blobContributorRoleId
    principalId: functionApps[i].identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

output storageAccountName string = storage.name
output functionAppNames array = [for (region, i) in regions: functionApps[i].name]
output functionAppPrincipalIds array = [for (region, i) in regions: functionApps[i].identity.principalId]
