param prefix string = 'cptdazsharepoint'
param customData string = loadTextContent('./vm.azcli.yaml')
param myObjectId string
param vmAdminName string

param location string = resourceGroup().location
param logicAppName string = 'myLogicApp'

// NETWORK -----------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: prefix
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: prefix
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
      {
        name: 'logicapp'
        properties: {
          addressPrefix: '10.0.1.0/24'
          delegations: [
            {
              name: '${prefix}logicapp'
              properties: {
                serviceName: 'Microsoft.Web/serverfarms'
              }
            }
          ]
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
    ]
  }
}

resource bastionHost 'Microsoft.Network/bastionHosts@2024-01-01' = {
  name: prefix
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    ipConfigurations: [
      {
        name: 'bastionHostIpConfig'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/AzureBastionSubnet'
          }
          publicIPAddress: {
            id: pubIpBastion.id
          }
        }
      }
    ]
  }
}

resource pubIpBastion 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${prefix}bastion'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// VM -----------------------------------------------------------------------------
resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: prefix
  location: location
  properties: {
    ipConfigurations: [
      {
        name: prefix
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${vnet.id}/subnets/${prefix}'
          }
          primary: true
          privateIPAddressVersion: 'IPv4'
        }
      }
    ]
    dnsSettings: {
      dnsServers: []
    }
    enableAcceleratedNetworking: false
    enableIPForwarding: false
  }
}

resource sshkey 'Microsoft.Compute/sshPublicKeys@2021-07-01' = {
  name: prefix
  location: location
  properties: {
    publicKey: loadTextContent('./ssh/chpinoto.pub')
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: prefix
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_D2s_v3'
    }
    storageProfile: {
      osDisk: {
        name: prefix
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
        deleteOption: 'Delete'
      }
      imageReference: {
        publisher: 'Canonical'
        offer: 'UbuntuServer'
        sku: '18.04-LTS'
        version: 'latest'
      }
    }
    osProfile: {
      computerName: prefix
      adminUsername: vmAdminName
      customData: !empty(customData) ? base64(customData) : null
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/chpinoto/.ssh/authorized_keys'
              keyData: sshkey.properties.publicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

resource vmaadextension 'Microsoft.Compute/virtualMachines/extensions@2020-12-01' = {
  parent: vm
  name: 'AADSSHLoginForLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
  }
}

var roleVirtualMachineAdministratorName = '1c0163c0-47e6-4577-8991-ea5c82e286e4' //Virtual Machine Administrator Login

resource raMe2VM 'Microsoft.Authorization/roleAssignments@2018-01-01-preview' = {
  name: guid(resourceGroup().id, 'raMe2VMHub')
  properties: {
    principalId: myObjectId
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', roleVirtualMachineAdministratorName)
  }
}

// STORAGE -----------------------------------------------------------------------------
resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' = {
  name: prefix
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      // virtualNetworkRules: [
      //   {
      //     id: '${vnet.id}/subnets/default'
      //   }
      // ]
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: storageAccount
  properties: {}
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: prefix
  parent: blobService
  properties: {}
}

var roleStorageBlobDataContributorName = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' //Storage Blob Data Contributor

resource rablobcontributor 'Microsoft.Authorization/roleAssignments@2018-01-01-preview' = {
  name: guid(resourceGroup().id, 'rablobcontributort')
  properties: {
    principalId: vm.identity.principalId
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/RoleDefinitions', roleStorageBlobDataContributorName)
  }
  dependsOn: [
    storageAccount
  ]
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: '${prefix}peblob'
  location: location
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/${prefix}'
    }
    privateLinkServiceConnections: [
      {
        name: '${prefix}peblob'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
    customNetworkInterfaceName: '${prefix}peblob'
  }
}

resource privateDnsZonesPrivatelinkBlobCoreWindowsNet 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.core.windows.net'
  location: 'global'
}

resource pePrivateDnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2020-06-01' = {
  name: '${prefix}peblob'
  parent: privateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: '${prefix}peblob'
        properties: {
          privateDnsZoneId: privateDnsZonesPrivatelinkBlobCoreWindowsNet.id
        }
      }
    ]
  }
}

// Link private DNS zone to virtual network
resource vNetLinkBlob 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  name: prefix
  location: 'global'
  parent: privateDnsZonesPrivatelinkBlobCoreWindowsNet
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// MONITORING -----------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2021-06-01' = {
  name: prefix
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource diaagw 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: prefix
  properties: {
    workspaceId: law.id
    logs: [
      {
        category: 'StorageRead'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'StorageWrite'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
      {
        category: 'StorageDelete'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
  scope: blobService
}

// LOGIC APP -----------------------------------------------------------------------------

resource serverfarm 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: prefix
  location: location
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
    size: 'WS1'
    family: 'WS'
    capacity: 1
  }
  kind: 'elastic'
  properties: {
    perSiteScaling: false
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 20
    isSpot: false
    reserved: false
    isXenon: false
    hyperV: false
    targetWorkerCount: 0
    targetWorkerSizeId: 0
    zoneRedundant: false
  }
}

resource webSite 'Microsoft.Web/sites@2023-12-01' = {
  name: prefix
  location: location
  kind: 'functionapp,workflowapp'
  properties: {
    enabled: true
    hostNameSslStates: [
      {
        name: '${prefix}.azurewebsites.net'
        sslState: 'Disabled'
        hostType: 'Standard'
      }
      {
        name: '${prefix}.scm.azurewebsites.net'
        sslState: 'Disabled'
        hostType: 'Repository'
      }
    ]
    serverFarmId: serverfarm.id
    publicNetworkAccess: 'Enabled'
    storageAccountRequired: false
    virtualNetworkSubnetId: '${vnet.id}/subnets/logicapp'
  }
}

// Even if we define both connections here, we will set them up via the azure portal for now
resource connectionSharepoint 'Microsoft.Web/connections@2016-06-01' = {
  name: 'sharepointonline'
  location: location
  properties: {
    api: {
      id: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Web/locations/${location}/managedApis/sharepointonline'
    }
    displayName: 'sharepointonline'
  }
}

resource connectionAzureblob 'Microsoft.Web/connections@2016-06-01' = {
  name: 'azureblob'
  location: location
  properties: {
    api: {
      name: 'azureblob'
      id: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Web/locations/${location}/managedApis/azureblob'
    }
    displayName: 'azureblob'
  }
}

