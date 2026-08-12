[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

function Invoke-GraphRest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $false)][string]$Body
  )

  $graphToken = Get-AzCliAccessToken -ResourceUrl 'https://graph.microsoft.com'
  $requestParams = @{
    Method  = $Method
    Uri     = $Uri
    Headers = @{ Authorization = "Bearer $graphToken" }
  }

  if (-not [string]::IsNullOrWhiteSpace($Body)) {
    $requestParams['ContentType'] = 'application/json'
    $requestParams['Body'] = $Body
  }

  $response = Invoke-RestMethod @requestParams
  if ($null -eq $response) {
    return $null
  }

  return $response
}

function Get-AzCliAccessToken {
  param([Parameter(Mandatory = $true)][string]$ResourceUrl)

  $token = & az account get-access-token --resource $ResourceUrl --query accessToken -o tsv --only-show-errors
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Could not acquire an Azure CLI access token for resource '$ResourceUrl'."
  }

  return $token.Trim()
}

function Get-AzCliUserPrincipalName {
  $upn = & az account show --query user.name -o tsv --only-show-errors
  if ([string]::IsNullOrWhiteSpace($upn)) {
    throw 'Could not determine the signed-in Azure CLI user principal name.'
  }

  return $upn.Trim()
}

function Connect-ExchangeForBootstrap {
  $upn = Get-AzCliUserPrincipalName
  $outlookToken = Get-AzCliAccessToken -ResourceUrl 'https://outlook.office365.com'

  try {
    Connect-ExchangeOnline -AccessToken $outlookToken -UserPrincipalName $upn -ShowBanner:$false | Out-Null
  }
  catch {
    Write-Warning "Exchange Online access-token auth failed. Falling back to device auth. Error: $($_.Exception.Message)"
    Connect-ExchangeOnline -ShowBanner:$false -Device | Out-Null
  }
}

function Connect-ComplianceForBootstrap {
  param([Parameter(Mandatory = $true)][string]$Organization)

  $upn = Get-AzCliUserPrincipalName
  $complianceToken = Get-AzCliAccessToken -ResourceUrl 'https://ps.compliance.protection.outlook.com'

  try {
    Connect-IPPSSession -AccessToken $complianceToken -UserPrincipalName $upn -ShowBanner:$false | Out-Null
    return
  }
  catch {
    Write-Warning "Security & Compliance PowerShell access-token auth with UserPrincipalName failed. Retrying with Organization. Error: $($_.Exception.Message)"
  }

  try {
    Connect-IPPSSession -AccessToken $complianceToken -Organization $Organization -ShowBanner:$false | Out-Null
    return $true
  }
  catch {
    Write-Warning "Security & Compliance PowerShell access-token auth failed: $($_.Exception.Message)"
    return $false
  }
}

function Get-ExchangeOrganizationDomain {
  param([Parameter(Mandatory = $false)][string]$ExistingValue)

  if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
    return $ExistingValue.Trim()
  }

  try {
    $domainResponse = Invoke-GraphRest -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/domains?$select=id,isInitial'
    if ($domainResponse -and $domainResponse.value) {
      $initialDomain = @($domainResponse.value | Where-Object { $_.isInitial -eq $true }) | Select-Object -First 1
      if ($initialDomain -and $initialDomain.id) {
        return [string]$initialDomain.id
      }
    }
  }
  catch {
    Write-Warning "Graph domain lookup failed: $($_.Exception.Message)"
  }

  $acceptedDomain = Get-AcceptedDomain | Where-Object { $_.DomainName.Domain -like '*.onmicrosoft.com' } | Sort-Object Default -Descending | Select-Object -First 1
  if ($acceptedDomain -and $acceptedDomain.DomainName -and $acceptedDomain.DomainName.Domain) {
    return [string]$acceptedDomain.DomainName.Domain
  }

  throw 'Unable to determine the tenant initial domain required for Exchange managed identity connections.'
}

function Ensure-ExchangeManageAsAppAssignment {
  param(
    [Parameter(Mandatory = $true)][string]$ManagedIdentityObjectId
  )

  $managedIdentitySp = Invoke-GraphRest -Method 'GET' -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals/{0}?`$select=id,appId" -f $ManagedIdentityObjectId)
  $exchangeResourceResponse = Invoke-GraphRest -Method 'GET' -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000002-0000-0ff1-ce00-000000000000'&`$select=id,appId"
  $exchangeResourceSp = @($exchangeResourceResponse.value | Select-Object -First 1)
  $exchangeManageAsAppRoleId = 'dc50a0fb-09a3-484d-be87-e023b12c6440'

  $existingAssignmentsResponse = Invoke-GraphRest -Method 'GET' -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals/{0}/appRoleAssignments?`$select=id,resourceId,appRoleId" -f $ManagedIdentityObjectId)
  $existingAssignments = @($existingAssignmentsResponse.value)
  $assignmentExists = @(
    $existingAssignments | Where-Object {
      [string]$_.ResourceId -eq [string]$exchangeResourceSp.Id -and
      [string]$_.AppRoleId -eq $exchangeManageAsAppRoleId
    }
  ).Count -gt 0

  if (-not $assignmentExists) {
    $payload = @{
      principalId = $ManagedIdentityObjectId
      resourceId  = $exchangeResourceSp.Id
      appRoleId   = $exchangeManageAsAppRoleId
    } | ConvertTo-Json -Compress

    Invoke-GraphRest -Method 'POST' -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals/{0}/appRoleAssignments" -f $ManagedIdentityObjectId) -Body $payload | Out-Null
  }

  return $managedIdentitySp
}

function Ensure-ExchangeServicePrincipal {
  param(
    [Parameter(Mandatory = $true)][string]$ManagedIdentityObjectId,
    [Parameter(Mandatory = $true)][string]$ManagedIdentityAppId
  )

  $existingSp = @(Get-ServicePrincipal | Where-Object {
      $appIdValue = if ($_.PSObject.Properties.Match('AppId').Count -gt 0) { [string]$_.AppId } else { '' }
      $objectIdValue = if ($_.PSObject.Properties.Match('ObjectId').Count -gt 0) { [string]$_.ObjectId } else { '' }
      $serviceIdValue = if ($_.PSObject.Properties.Match('ServiceId').Count -gt 0) { [string]$_.ServiceId } else { '' }

      $appIdValue -eq $ManagedIdentityAppId -or
      $objectIdValue -eq $ManagedIdentityObjectId -or
      $serviceIdValue -eq $ManagedIdentityObjectId
    } | Select-Object -First 1)

  if ($existingSp.Count -eq 0) {
    New-ServicePrincipal -AppId $ManagedIdentityAppId -ObjectId $ManagedIdentityObjectId -DisplayName 'exchange-auditing-automation' | Out-Null
  }
}

function Ensure-MailboxAuditingRole {
  $roleName = 'Mailbox Auditing'
  $allowedSetMailboxParameters = @('Identity', 'AuditAdmin', 'AuditDelegate', 'AuditOwner', 'AuditEnabled', 'AuditLogAgeLimit')

  if (-not (Get-ManagementRole -Identity $roleName -ErrorAction SilentlyContinue)) {
    New-ManagementRole -Name $roleName -Parent 'Audit Logs' | Out-Null
  }

  $entries = @(Get-ManagementRoleEntry "$roleName\*" -ErrorAction Stop)
  foreach ($entry in $entries) {
    if ($entry.Name -notin @('Get-Mailbox', 'Set-Mailbox')) {
      Remove-ManagementRoleEntry -Identity "$roleName\$($entry.Name)" -Confirm:$false | Out-Null
    }
  }

  if (Get-ManagementRoleEntry "$roleName\Set-Mailbox" -ErrorAction SilentlyContinue) {
    Remove-ManagementRoleEntry -Identity "$roleName\Set-Mailbox" -Confirm:$false | Out-Null
  }

  Add-ManagementRoleEntry -Identity "$roleName\Set-Mailbox" -Parameters $allowedSetMailboxParameters | Out-Null
}

function Ensure-RoleGroupMembership {
  param([Parameter(Mandatory = $true)][string]$ManagedIdentityObjectId)

  $roleGroupName = 'Advanced Auditing Management'
  $roleName = 'Mailbox Auditing'

  if (-not (Get-RoleGroup -Identity $roleGroupName -ErrorAction SilentlyContinue)) {
    New-RoleGroup `
      -Name $roleGroupName `
      -Description 'Limited scope for Azure Automation to set Advanced Auditing entries' `
      -Roles $roleName `
      -Confirm:$false | Out-Null
  }

  $members = @(Get-RoleGroupMember -Identity $roleGroupName -ResultSize Unlimited)
  $memberExists = @(
    $members | Where-Object {
      @(
        [string]$_.Id,
        [string]$_.Guid,
        [string]$_.ExternalDirectoryObjectId,
        [string]$_.Name
      ) -contains $ManagedIdentityObjectId
    }
  ).Count -gt 0

  if (-not $memberExists) {
    Add-RoleGroupMember -Identity $roleGroupName -Member $ManagedIdentityObjectId -Confirm:$false | Out-Null

    $members = @(Get-RoleGroupMember -Identity $roleGroupName -ResultSize Unlimited)
    $memberExists = @(
      $members | Where-Object {
        @(
          [string]$_.Id,
          [string]$_.Guid,
          [string]$_.ExternalDirectoryObjectId,
          [string]$_.Name
        ) -contains $ManagedIdentityObjectId
      }
    ).Count -gt 0

    if (-not $memberExists) {
      throw "Managed identity '$ManagedIdentityObjectId' was not added to role group '$roleGroupName'."
    }
  }
}

function Ensure-AuditRetentionPolicy {
  param(
    [Parameter(Mandatory = $true)][string]$PolicyName
  )

  if (-not (Get-UnifiedAuditLogRetentionPolicy -Identity $PolicyName -ErrorAction SilentlyContinue)) {
    New-UnifiedAuditLogRetentionPolicy `
      -Name $PolicyName `
      -Description 'One year retention policy for all audit records' `
      -RetentionDuration 'TwelveMonths' `
      -Priority 10 | Out-Null
  }
}

Write-Section -Message 'Loading azd environment values'
$azdValues = Get-AzdEnvironmentValues
$subscriptionId = Get-ValueFromEnvironment -Name 'AZURE_SUBSCRIPTION_ID' -AzdValues $azdValues
$resourceGroupName = Get-ValueFromEnvironment -Name 'AZURE_RESOURCE_GROUP' -AzdValues $azdValues
$automationAccountName = Get-ValueFromEnvironment -Name 'AUTOMATION_ACCOUNT_NAME' -AzdValues $azdValues
$managedIdentityObjectId = Get-ValueFromEnvironment -Name 'AUTOMATION_PRINCIPAL_ID' -AzdValues $azdValues
$validateConnectionRunbookName = Get-ValueFromEnvironment -Name 'VALIDATE_CONNECTION_RUNBOOK_NAME' -AzdValues $azdValues
$validateConfigurationRunbookName = Get-ValueFromEnvironment -Name 'VALIDATE_CONFIGURATION_RUNBOOK_NAME' -AzdValues $azdValues
$exchangeOrganizationVariableName = Get-ValueFromEnvironment -Name 'EXCHANGE_ORGANIZATION_VARIABLE_NAME' -AzdValues $azdValues

if ([string]::IsNullOrWhiteSpace($subscriptionId) -or [string]::IsNullOrWhiteSpace($resourceGroupName) -or [string]::IsNullOrWhiteSpace($automationAccountName) -or [string]::IsNullOrWhiteSpace($managedIdentityObjectId)) {
  throw 'Required azd environment values were not found after provision.'
}

Write-Section -Message 'Installing required local PowerShell modules'
Ensure-PowerShellModule -Name 'ExchangeOnlineManagement' -MinimumVersion '3.10.1'

Import-Module ExchangeOnlineManagement -MinimumVersion '3.10.1' -Force

Write-Section -Message 'Connecting to Azure, Exchange Online, and Security & Compliance PowerShell'
Ensure-Command -Name 'az'
Connect-ExchangeForBootstrap

$exchangeOrganization = Get-ExchangeOrganizationDomain -ExistingValue (Get-ValueFromEnvironment -Name 'EXCHANGE_ORGANIZATION' -AzdValues $azdValues)
Write-Host "Resolved Exchange organization: $exchangeOrganization"

$complianceConnected = Connect-ComplianceForBootstrap -Organization $exchangeOrganization

Write-Section -Message 'Configuring audit prerequisites'
$adminAuditConfig = Get-AdminAuditLogConfig
if (-not $adminAuditConfig.UnifiedAuditLogIngestionEnabled) {
  Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true
}

$retentionPolicyName = 'All Records - 1 Year'
if ($complianceConnected) {
  Ensure-AuditRetentionPolicy -PolicyName $retentionPolicyName
}
else {
  Write-Warning "Skipping unified audit log retention policy bootstrap because Security & Compliance PowerShell authentication was not available. Configure '$retentionPolicyName' manually if needed."
}

Write-Section -Message 'Granting managed identity Exchange application access'
$managedIdentitySp = Ensure-ExchangeManageAsAppAssignment -ManagedIdentityObjectId $managedIdentityObjectId
Ensure-ExchangeServicePrincipal -ManagedIdentityObjectId $managedIdentityObjectId -ManagedIdentityAppId $managedIdentitySp.AppId
Ensure-MailboxAuditingRole
Ensure-RoleGroupMembership -ManagedIdentityObjectId $managedIdentityObjectId

Write-Section -Message 'Persisting automation variables'
Set-AutomationVariableValue `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -AutomationAccountName $automationAccountName `
  -VariableName $exchangeOrganizationVariableName `
  -Value $exchangeOrganization

Set-AzdEnvironmentValue -Name 'EXCHANGE_ORGANIZATION' -Value $exchangeOrganization

Write-Section -Message 'Publishing repository runbooks to Azure Automation'
$runbooksPath = Get-RunbooksPath
Publish-AutomationRunbookContent `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -AutomationAccountName $automationAccountName `
  -RunbookName 'Enable-AdvancedAuditing' `
  -FilePath (Join-Path -Path $runbooksPath -ChildPath 'Enable-AdvancedAuditing.ps1')

Publish-AutomationRunbookContent `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -AutomationAccountName $automationAccountName `
  -RunbookName $validateConnectionRunbookName `
  -FilePath (Join-Path -Path $runbooksPath -ChildPath 'Validate-ExchangeManagedIdentity.ps1')

Publish-AutomationRunbookContent `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -AutomationAccountName $automationAccountName `
  -RunbookName $validateConfigurationRunbookName `
  -FilePath (Join-Path -Path $runbooksPath -ChildPath 'Validate-AdvancedAuditingConfiguration.ps1')

Write-Section -Message 'Running advanced auditing remediation runbook'
Start-AutomationRunbookAndWait `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -AutomationAccountName $automationAccountName `
  -RunbookName 'Enable-AdvancedAuditing' | Out-Null

Write-Section -Message 'Running validation runbooks'
Start-AutomationRunbookAndWait `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -AutomationAccountName $automationAccountName `
  -RunbookName $validateConnectionRunbookName | Out-Null

Start-AutomationRunbookAndWait `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -AutomationAccountName $automationAccountName `
  -RunbookName $validateConfigurationRunbookName | Out-Null

Write-Section -Message 'Advanced auditing bootstrap completed'
