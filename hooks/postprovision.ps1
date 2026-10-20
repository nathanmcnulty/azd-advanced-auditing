#Requires -Version 7.6
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'JobScheduleOwnership.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'AuditOperationalState.ps1')

function Invoke-GraphRest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $false)][string]$Body
  )

  $endpoint = [uri]$Uri
  if ($endpoint.Scheme -cne 'https' -or $endpoint.Host -cne 'graph.microsoft.com' -or $endpoint.Port -ne 443 -or $endpoint.UserInfo -or $endpoint.Fragment -or $endpoint.AbsolutePath -notmatch '^/v1\.0/') {
    throw 'Graph bootstrap requires an explicit public-cloud Graph endpoint.'
  }
  $graphToken = Get-AzCliAccessToken -ResourceUrl 'https://graph.microsoft.com'
  $requestParams = @{
    Method  = $Method
    Uri     = $Uri
    Headers = @{ Authorization = "Bearer $graphToken" }
    MaximumRedirection = 0
    TimeoutSec = 30
  }

  if (-not [string]::IsNullOrWhiteSpace($Body)) {
    $requestParams['ContentType'] = 'application/json'
    $requestParams['Body'] = $Body
  }

  $null = Assert-AuditOperatorTarget
  $response = Invoke-RestMethod @requestParams
  if ($null -eq $response) {
    return $null
  }

  return $response
}

function Get-AzCliAccessToken {
  param([Parameter(Mandatory = $true)][string]$ResourceUrl)
  $target = Assert-AuditOperatorTarget
  return (Get-AuditScopedAccessToken -ResourceUrl $ResourceUrl -Target $target)
}

function Get-AzCliUserPrincipalName {
  return (Assert-AuditOperatorTarget).UserPrincipalName
}

function Assert-AuditNativeContext {
  param([ValidateSet('Exchange', 'Compliance')][string]$Service = 'Exchange', [string]$CommandName)

  $target = Assert-AuditOperatorTarget
  try {
    $connections = @(Get-ConnectionInformation -ErrorAction Stop)
    # Unknown session kind cannot establish which unprefixed commands it owns.
    if (@($connections | Where-Object { $_.IsEopSession -isnot [bool] }).Count) { throw 'Unknown session kind.' }
    $compliance = $Service -eq 'Compliance'
    $selected = @($connections | Where-Object { $_.IsEopSession -eq $compliance })
    if ($selected.Count -ne 1) { throw 'Ambiguous or absent native session.' }
    $connection = $selected[0]
    if ($connection.TenantID -isnot [string] -or $connection.UserPrincipalName -isnot [string] -or
        $connection.TenantID -ine $target.TenantId -or $connection.UserPrincipalName -ine $target.UserPrincipalName -or
        $connection.State -cne 'Connected' -or $connection.TokenStatus -cne 'Active' -or
        $connection.ModulePrefix -or $connection.DelegatedOrganization -or $connection.CertificateAuthentication -isnot [bool] -or $connection.CertificateAuthentication -ne $false) {
      throw 'Native session does not match the selected operator.'
    }
    if ($CommandName) {
      # Exchange and Purview can export identically named commands. Verify the
      # command PowerShell will actually dispatch belongs to this exact session.
      $command = Get-Command -Name $CommandName -ErrorAction Stop
      $moduleName = ([string]$connection.ModuleName -split '[\\/]')[-1]
      if ([string]::IsNullOrWhiteSpace($moduleName) -or $command.CommandType -ne 'Function' -or
          $command.ModuleName -cne $moduleName) { throw 'Native command is not owned by the verified session.' }
    }
    $endpoint = [uri]$connection.ConnectionUri
    $validHost = if ($compliance) {
      $endpoint.Host -eq 'ps.compliance.protection.outlook.com' -or $endpoint.Host.EndsWith('.ps.compliance.protection.outlook.com', [StringComparison]::OrdinalIgnoreCase)
    } else { $endpoint.Host -eq 'outlook.office365.com' }
    if ($endpoint.Scheme -cne 'https' -or $endpoint.Port -ne 443 -or $endpoint.UserInfo -or $endpoint.Fragment -or -not $validHost -or
        ([datetimeoffset]$connection.TokenExpiryTimeUTC) -le [datetimeoffset]::UtcNow) { throw 'Inactive or unexpected native endpoint.' }
  } catch { throw (New-AuditTargetGuardException -Message "Cannot verify the expected tenant, operator and active $Service session; no mutation is permitted.") }
}

function Connect-ExchangeForBootstrap {
  $upn = Get-AzCliUserPrincipalName
  $tokenUnavailable = $false
  try { $outlookToken = Get-AzCliAccessToken -ResourceUrl 'https://outlook.office365.com' }
  catch {
    # A failed CLI token read may use the existing browser path. A returned
    # token with wrong or malformed context must never trigger that fallback.
    if (-not $_.Exception.Data['AuditTokenUnavailable']) { throw }
    $tokenUnavailable = $true
  }
  try {
    if ($tokenUnavailable) { throw 'Cached Outlook token unavailable.' }
    Connect-ExchangeOnline -AccessToken $outlookToken -UserPrincipalName $upn -ShowBanner:$false -ErrorAction Stop | Out-Null
  }
  catch {
    Write-Warning 'Exchange Online access-token connection failed. Trying the normal cached account or browser sign-in.'
    $null = Assert-AuditOperatorTarget
    try {
      Connect-ExchangeOnline -UserPrincipalName $upn -ShowBanner:$false -ErrorAction Stop | Out-Null
    }
    catch { throw 'Exchange Online cached or browser sign-in could not complete. Review the selected account and interactive authentication state.' }
  }
  Assert-AuditNativeContext -Service Exchange
}

function Connect-ComplianceForBootstrap {
  param([Parameter(Mandatory = $true)][string]$Organization)

  $upn = Get-AzCliUserPrincipalName
  $complianceToken = Get-AzCliAccessToken -ResourceUrl 'https://ps.compliance.protection.outlook.com'
  $connected = $false
  try {
    Connect-IPPSSession -AccessToken $complianceToken -UserPrincipalName $upn -CommandName @('Get-UnifiedAuditLogRetentionPolicy', 'New-UnifiedAuditLogRetentionPolicy') -ShowBanner:$false -ErrorAction Stop | Out-Null
    $connected = $true
  }
  catch { Write-Warning 'Security & Compliance access-token connection failed. Retrying the existing Organization fallback.' }

  if (-not $connected) {
    $null = Assert-AuditOperatorTarget
    try {
      Connect-IPPSSession -AccessToken $complianceToken -Organization $Organization -CommandName @('Get-UnifiedAuditLogRetentionPolicy', 'New-UnifiedAuditLogRetentionPolicy') -ShowBanner:$false -ErrorAction Stop | Out-Null
      $connected = $true
    }
    catch {
      Write-Warning 'Security & Compliance access-token connection failed; retention bootstrap remains unavailable.'
      return $false
    }
  }
  # Context mismatch is fatal even when authentication reported success.
  Assert-AuditNativeContext -Service Compliance
  return $true
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
    if ($_.Exception.Data['AuditTargetGuard']) { throw }
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
    Assert-AuditNativeContext -Service Exchange -CommandName 'New-ServicePrincipal'
    New-ServicePrincipal -AppId $ManagedIdentityAppId -ObjectId $ManagedIdentityObjectId -DisplayName 'exchange-auditing-automation' | Out-Null
  }
}

function Ensure-MailboxAuditingRole {
  $roleName = 'Mailbox Auditing'
  $allowedSetMailboxParameters = @('Identity', 'AuditAdmin', 'AuditDelegate', 'AuditOwner', 'AuditEnabled', 'AuditLogAgeLimit')
  $allowedCommands = @('Get-Mailbox', 'Get-MailboxAuditBypassAssociation', 'Set-Mailbox')

  if (-not (Get-ManagementRole -Identity $roleName -ErrorAction SilentlyContinue)) {
    Assert-AuditNativeContext -Service Exchange -CommandName 'New-ManagementRole'
    New-ManagementRole -Name $roleName -Parent 'Audit Logs' | Out-Null
  }

  $entries = @(Get-ManagementRoleEntry "$roleName\*" -ErrorAction Stop)
  foreach ($entry in $entries) {
    if ($entry.Name -notin $allowedCommands) {
      Assert-AuditNativeContext -Service Exchange -CommandName 'Remove-ManagementRoleEntry'
      Remove-ManagementRoleEntry -Identity "$roleName\$($entry.Name)" -Confirm:$false | Out-Null
    }
  }

  foreach ($commandName in @('Get-Mailbox', 'Get-MailboxAuditBypassAssociation')) {
    if (-not (Get-ManagementRoleEntry "$roleName\$commandName" -ErrorAction SilentlyContinue)) {
      Assert-AuditNativeContext -Service Exchange -CommandName 'Add-ManagementRoleEntry'
      Add-ManagementRoleEntry -Identity "$roleName\$commandName" | Out-Null
    }
  }

  if (Get-ManagementRoleEntry "$roleName\Set-Mailbox" -ErrorAction SilentlyContinue) {
    Assert-AuditNativeContext -Service Exchange -CommandName 'Remove-ManagementRoleEntry'
    Remove-ManagementRoleEntry -Identity "$roleName\Set-Mailbox" -Confirm:$false | Out-Null
  }

  Assert-AuditNativeContext -Service Exchange -CommandName 'Add-ManagementRoleEntry'
  Add-ManagementRoleEntry -Identity "$roleName\Set-Mailbox" -Parameters $allowedSetMailboxParameters | Out-Null
}

function Ensure-RoleGroupMembership {
  param([Parameter(Mandatory = $true)][string]$ManagedIdentityObjectId)

  $roleGroupName = 'Advanced Auditing Management'
  $roleName = 'Mailbox Auditing'

  if (-not (Get-RoleGroup -Identity $roleGroupName -ErrorAction SilentlyContinue)) {
    Assert-AuditNativeContext -Service Exchange -CommandName 'New-RoleGroup'
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
    Assert-AuditNativeContext -Service Exchange -CommandName 'Add-RoleGroupMember'
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
    Assert-AuditNativeContext -Service Compliance -CommandName 'New-UnifiedAuditLogRetentionPolicy'
    New-UnifiedAuditLogRetentionPolicy `
      -Name $PolicyName `
      -Description 'One year retention policy for all audit records' `
      -RetentionDuration 'TwelveMonths' `
      -Priority 10 | Out-Null
  }

  $policy = Get-UnifiedAuditLogRetentionPolicy -Identity $PolicyName -ErrorAction Stop
  $policyFailures = [System.Collections.Generic.List[string]]::new()

  if ([string]$policy.RetentionDuration -ne 'TwelveMonths') {
    $policyFailures.Add("RetentionDuration is '$($policy.RetentionDuration)', expected 'TwelveMonths'")
  }

  if ([int]$policy.Priority -ne 10) {
    $policyFailures.Add("Priority is '$($policy.Priority)', expected '10'")
  }

  if (@($policy.RecordTypes).Count -gt 0) {
    $policyFailures.Add('RecordTypes is restricted; expected all record types')
  }

  if (@($policy.UserIds).Count -gt 0) {
    $policyFailures.Add('UserIds is restricted; expected all users')
  }

  if ($policyFailures.Count -gt 0) {
    throw "Audit retention policy '$PolicyName' is not configured as expected: $($policyFailures -join '; ')"
  }
}

Write-Section -Message 'Loading azd environment values'
$azdValues = Get-AzdEnvironmentValues
$subscriptionId = Get-ValueFromEnvironment -Name 'AZURE_SUBSCRIPTION_ID' -AzdValues $azdValues
$null = Assert-AuditOperatorTarget -SubscriptionId $subscriptionId
$resourceGroupName = Get-ValueFromEnvironment -Name 'AZURE_RESOURCE_GROUP' -AzdValues $azdValues
$automationAccountName = Get-ValueFromEnvironment -Name 'AUTOMATION_ACCOUNT_NAME' -AzdValues $azdValues
$managedIdentityObjectId = Get-ValueFromEnvironment -Name 'AUTOMATION_PRINCIPAL_ID' -AzdValues $azdValues
$validateConnectionRunbookName = Get-ValueFromEnvironment -Name 'VALIDATE_CONNECTION_RUNBOOK_NAME' -AzdValues $azdValues
$validateConfigurationRunbookName = Get-ValueFromEnvironment -Name 'VALIDATE_CONFIGURATION_RUNBOOK_NAME' -AzdValues $azdValues
$exchangeOrganizationVariableName = Get-ValueFromEnvironment -Name 'EXCHANGE_ORGANIZATION_VARIABLE_NAME' -AzdValues $azdValues
$jobScheduleId = Get-ValueFromEnvironment -Name 'AUTOMATION_JOB_SCHEDULE_ID' -AzdValues $azdValues

if ([string]::IsNullOrWhiteSpace($subscriptionId) -or [string]::IsNullOrWhiteSpace($resourceGroupName) -or [string]::IsNullOrWhiteSpace($automationAccountName) -or [string]::IsNullOrWhiteSpace($managedIdentityObjectId) -or [string]::IsNullOrWhiteSpace($jobScheduleId)) {
  throw 'Required azd environment values were not found after provision.'
}

Write-Section -Message 'Recording provisioned Automation ownership'
Ensure-Command -Name 'az'
$accountId = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}' -f $subscriptionId, $resourceGroupName, $automationAccountName
$accountJson = & az automation account show --subscription $subscriptionId --resource-group $resourceGroupName --name $automationAccountName --only-show-errors -o json
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountJson)) { throw 'Could not verify the provisioned Automation account.' }
$jobScheduleUri = 'https://management.azure.com{0}/jobSchedules/{1}?api-version=2023-11-01' -f $accountId, $jobScheduleId
$jobScheduleJson = & az rest --subscription $subscriptionId --method GET --uri $jobScheduleUri --only-show-errors -o json
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($jobScheduleJson)) { throw 'Could not verify the provisioned Automation jobSchedule.' }
Assert-AuditOwnershipReceiptTarget -ExpectedAccountId $accountId -ExpectedPrincipalId $managedIdentityObjectId -ExpectedJobScheduleId $jobScheduleId `
  -Account ($accountJson | ConvertFrom-Json -ErrorAction Stop) -JobSchedule ($jobScheduleJson | ConvertFrom-Json -ErrorAction Stop)
Set-AzdEnvironmentValue -Name 'AUTOMATION_OWNED_ACCOUNT_ID' -Value $accountId
Set-AzdEnvironmentValue -Name 'AUTOMATION_OWNED_PRINCIPAL_ID' -Value $managedIdentityObjectId
Set-AzdEnvironmentValue -Name 'AUTOMATION_OWNED_JOB_SCHEDULE_ID' -Value $jobScheduleId

Write-Section -Message 'Installing required local PowerShell modules'
Ensure-PowerShellModule -Name 'ExchangeOnlineManagement' -MinimumVersion '3.10.1'

Import-Module ExchangeOnlineManagement -MinimumVersion '3.10.1' -Force

Write-Section -Message 'Connecting to Azure, Exchange Online, and Security & Compliance PowerShell'
Ensure-Command -Name 'az'
Connect-ExchangeForBootstrap

$exchangeOrganization = Get-ExchangeOrganizationDomain -ExistingValue (Get-ValueFromEnvironment -Name 'EXCHANGE_ORGANIZATION' -AzdValues $azdValues)
Write-Host "Resolved Exchange organization: $exchangeOrganization"

$complianceConnected = Connect-ComplianceForBootstrap -Organization $exchangeOrganization
$degradedConditions = [System.Collections.Generic.List[string]]::new()

Write-Section -Message 'Configuring audit prerequisites'
$adminAuditConfig = Get-AdminAuditLogConfig
if (-not $adminAuditConfig.UnifiedAuditLogIngestionEnabled) {
  Assert-AuditNativeContext -Service Exchange -CommandName 'Set-AdminAuditLogConfig'
  Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true

  $adminAuditConfig = Get-AdminAuditLogConfig
  if (-not $adminAuditConfig.UnifiedAuditLogIngestionEnabled) {
    throw 'Unified audit log ingestion is still disabled after attempting to enable it.'
  }
}

$retentionPolicyName = 'All Records - 1 Year'
$operationalAlertsEnabled = $false
# This optional resource flag must use the deployed azd output, never the
# process-first environment override used by general bootstrap inputs.
$operationalAlertsValue = if ($azdValues.ContainsKey('OPERATIONAL_ALERTS_ENABLED')) { $azdValues['OPERATIONAL_ALERTS_ENABLED'] } else { $null }
if (-not [bool]::TryParse([string]$operationalAlertsValue, [ref]$operationalAlertsEnabled)) {
  throw 'Deployed OPERATIONAL_ALERTS_ENABLED output is missing or invalid; optional state persistence cannot be selected safely.'
}
if ($complianceConnected) {
  try {
    Ensure-AuditRetentionPolicy -PolicyName $retentionPolicyName
  } catch {
    if ($_.Exception.Data['AuditTargetGuard']) { throw }
    if ($operationalAlertsEnabled) { Save-AuditRetentionSetupState -Enabled $true -SetupState 'setupFailed' -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName }
    throw
  }
  if ($operationalAlertsEnabled) { Save-AuditRetentionSetupState -Enabled $true -SetupState 'setupVerified' -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName }
}
else {
  if ($operationalAlertsEnabled) { Save-AuditRetentionSetupState -Enabled $true -SetupState 'setupUnavailable' -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName }
  $retentionWarning = "Unified audit log retention policy bootstrap was skipped because Security & Compliance PowerShell authentication was not available. Configure and validate '$retentionPolicyName' manually."
  $degradedConditions.Add($retentionWarning)
  Write-Warning $retentionWarning
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

Write-Section -Message 'Validating the managed identity connection'
Start-AutomationRunbookAndWait `
  -SubscriptionId $subscriptionId `
  -ResourceGroupName $resourceGroupName `
  -AutomationAccountName $automationAccountName `
  -RunbookName $validateConnectionRunbookName | Out-Null

$runbookFailures = [System.Collections.Generic.List[string]]::new()

Write-Section -Message 'Running advanced auditing remediation runbook'
try {
  Start-AutomationRunbookAndWait `
    -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -RunbookName 'Enable-AdvancedAuditing' | Out-Null
}
catch {
  if ($_.Exception.Data['AuditTargetGuard']) { throw }
  $runbookFailures.Add("Advanced auditing remediation failed: $($_.Exception.Message)")
  Write-Warning $runbookFailures[$runbookFailures.Count - 1]
}

Write-Section -Message 'Validating advanced auditing configuration'
try {
  Start-AutomationRunbookAndWait `
    -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName `
    -AutomationAccountName $automationAccountName `
    -RunbookName $validateConfigurationRunbookName | Out-Null
}
catch {
  if ($_.Exception.Data['AuditTargetGuard']) { throw }
  $runbookFailures.Add("Advanced auditing validation failed: $($_.Exception.Message)")
  Write-Warning $runbookFailures[$runbookFailures.Count - 1]
}

if ($runbookFailures.Count -gt 0) {
  throw ($runbookFailures -join [Environment]::NewLine)
}

if ($degradedConditions.Count -gt 0) {
  Write-Section -Message 'Advanced auditing bootstrap completed with required manual follow-up'
  foreach ($condition in $degradedConditions) {
    Write-Warning $condition
  }
}
else {
  Write-Section -Message 'Advanced auditing bootstrap completed'
}
