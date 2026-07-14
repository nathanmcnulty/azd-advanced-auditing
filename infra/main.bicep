targetScope = 'resourceGroup'

@description('Deployment location')
@metadata({
  azd: {
    type: 'location'
    default: 'eastus2'
  }
})
param location string = resourceGroup().location

@description('Environment name from azd')
param environmentName string = 'dev'

@description('Optional Automation account name. When omitted, the template derives one from the azd environment name.')
param automationAccountName string = ''

@description('Deployment timestamp used to calculate a schedule start time in the future')
param deploymentTimestamp string = utcNow()

@description('Stable GUID for the Automation Account jobSchedule. Managed by preprovision to avoid Azure Automation ghost-state conflicts after resource group deletion.')
param jobScheduleId string = newGuid()

@description('PowerShell script used as an initial placeholder until postprovision replaces the runbook content with the local repository version.')
param placeholderRunbookUri string = 'https://raw.githubusercontent.com/nathanmcnulty/nathanmcnulty/master/ExchangeOnline/Enable-AdvancedAuditing.ps1'

@description('Offset applied to the deployment timestamp so the first schedule start lands in the future.')
param scheduleStartOffset string = 'PT15M'

@description('Enable a can-not-delete lock on the Automation account.')
param enableResourceLock bool = true

var runtimeEnvironmentName = 'PowerShell-74-AdvancedAuditing'
var scheduleName = 'advanced-auditing-daily'
var mainRunbookName = 'Enable-AdvancedAuditing'
var validateConnectionRunbookName = 'Validate-ExchangeManagedIdentity'
var validateConfigurationRunbookName = 'Validate-AdvancedAuditingConfiguration'
var exchangeOrganizationVariableName = 'ExchangeOrganization'
var retentionPolicyNameVariableName = 'AuditRetentionPolicyName'
var normalizedEnvironmentName = replace(toLower(environmentName), '-', '')
var normalizedEnvironmentNameLength = length(normalizedEnvironmentName)
var automationNameSuffixStartIndex = max(0, normalizedEnvironmentNameLength - 24)
var automationNameSuffix = empty(normalizedEnvironmentName)
  ? 'audit'
  : substring(normalizedEnvironmentName, automationNameSuffixStartIndex, normalizedEnvironmentNameLength - automationNameSuffixStartIndex)
var resolvedAutomationAccountName = empty(automationAccountName) ? 'aaaudit${automationNameSuffix}' : automationAccountName
var tags = {
  workload: 'advanced-auditing'
  environment: toLower(environmentName)
  managedBy: 'azd'
}

resource automationAccount 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: resolvedAutomationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    disableLocalAuth: true
    publicNetworkAccess: true
  }
}

resource automationDeleteLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableResourceLock) {
  name: 'lock-cannot-delete-automation'
  scope: automationAccount
  properties: {
    level: 'CanNotDelete'
    notes: 'Prevents accidental deletion of the auditing automation account.'
  }
}

resource runtimeEnvironment 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  name: runtimeEnvironmentName
  parent: automationAccount
  location: location
  properties: {
    runtime: {
      language: 'PowerShell'
      version: '7.4'
    }
    defaultPackages: {}
    description: 'PowerShell 7.4 runtime environment for advanced auditing runbooks'
  }
}

resource packagePowerShellGet 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages@2024-10-23' = {
  name: 'PowerShellGet'
  parent: runtimeEnvironment
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/PowerShellGet'
    }
  }
}

resource packagePackageManagement 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages@2024-10-23' = {
  name: 'PackageManagement'
  parent: runtimeEnvironment
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/PackageManagement'
    }
  }
}

resource packageExchangeOnlineManagement 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages@2024-10-23' = {
  name: 'ExchangeOnlineManagement'
  parent: runtimeEnvironment
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/ExchangeOnlineManagement'
    }
  }
}

resource exchangeOrganizationVariable 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  name: exchangeOrganizationVariableName
  parent: automationAccount
  properties: {
    description: 'Tenant initial domain used when connecting to Exchange Online with the automation managed identity.'
    isEncrypted: false
    value: '""'
  }
}

resource retentionPolicyNameVariable 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  name: retentionPolicyNameVariableName
  parent: automationAccount
  properties: {
    description: 'Unified audit log retention policy configured by postprovision.'
    isEncrypted: false
    value: '"All Records - 1 Year"'
  }
}

resource mainRunbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  name: mainRunbookName
  parent: automationAccount
  location: location
  properties: {
    runbookType: 'PowerShell'
    logProgress: true
    logVerbose: true
    description: 'Ensures mailbox auditing is fully enabled for all user mailboxes.'
    publishContentLink: {
      uri: placeholderRunbookUri
      version: '1.0.0'
    }
    runtimeEnvironment: runtimeEnvironment.name
  }
  dependsOn: [
    packagePowerShellGet
    packagePackageManagement
    packageExchangeOnlineManagement
  ]
}

resource validateConnectionRunbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  name: validateConnectionRunbookName
  parent: automationAccount
  location: location
  properties: {
    runbookType: 'PowerShell'
    logProgress: true
    logVerbose: true
    description: 'Validates that the automation managed identity can connect to Exchange Online.'
    publishContentLink: {
      uri: placeholderRunbookUri
      version: '1.0.0'
    }
    runtimeEnvironment: runtimeEnvironment.name
  }
  dependsOn: [
    packagePowerShellGet
    packagePackageManagement
    packageExchangeOnlineManagement
  ]
}

resource validateConfigurationRunbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  name: validateConfigurationRunbookName
  parent: automationAccount
  location: location
  properties: {
    runbookType: 'PowerShell'
    logProgress: true
    logVerbose: true
    description: 'Validates that mailbox auditing values match the expected advanced auditing configuration.'
    publishContentLink: {
      uri: placeholderRunbookUri
      version: '1.0.0'
    }
    runtimeEnvironment: runtimeEnvironment.name
  }
  dependsOn: [
    packagePowerShellGet
    packagePackageManagement
    packageExchangeOnlineManagement
  ]
}

resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  name: scheduleName
  parent: automationAccount
  properties: {
    startTime: dateTimeAdd(deploymentTimestamp, scheduleStartOffset)
    expiryTime: '2099-12-31T23:59:00Z'
    interval: 1
    frequency: 'Day'
    timeZone: 'UTC'
  }
}

// disable-next-line use-stable-resource-identifiers
resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  name: jobScheduleId
  parent: automationAccount
  properties: {
    schedule: {
      name: schedule.name
    }
    runbook: {
      name: mainRunbook.name
    }
  }
}

output AUTOMATION_ACCOUNT_NAME string = automationAccount.name
output AUTOMATION_PRINCIPAL_ID string = automationAccount.identity.principalId
output MAIN_RUNBOOK_NAME string = mainRunbook.name
output VALIDATE_CONNECTION_RUNBOOK_NAME string = validateConnectionRunbook.name
output VALIDATE_CONFIGURATION_RUNBOOK_NAME string = validateConfigurationRunbook.name
output EXCHANGE_ORGANIZATION_VARIABLE_NAME string = exchangeOrganizationVariable.name
