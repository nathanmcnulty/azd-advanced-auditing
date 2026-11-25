[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

Write-Section -Message 'Removing the Automation account deletion lock'
Ensure-Command -Name 'az'

$environmentName = Get-AuditHookEnvironmentName
$azdValues = Get-AuditPinnedAzdEnvironmentValues -EnvironmentName $environmentName -RequireResourceValues
$context = New-AuditHookContext -EnvironmentName $environmentName -AzdValues $azdValues -TargetNames @()
$subscriptionId = $context.Operator.SubscriptionId
$resourceGroupName = [string]$azdValues['AZURE_RESOURCE_GROUP']
$automationAccountName = [string]$azdValues['AUTOMATION_ACCOUNT_NAME']

if ($resourceGroupName -notmatch '^[A-Za-z0-9_.()-]{1,90}$' -or $resourceGroupName.EndsWith('.') -or
    $automationAccountName -notmatch '^[A-Za-z0-9_-]{1,50}$') {
  throw (New-AuditOperatorContextException -Message 'The selected Automation lock scope is malformed.')
}

$lockId = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/providers/Microsoft.Authorization/locks/lock-cannot-delete-automation' -f $subscriptionId, $resourceGroupName, $automationAccountName)
$lockUri = "https://management.azure.com${lockId}?api-version=2016-09-01"
$token = Get-AuditHookArmToken $context $subscriptionId $context.Operator.TenantId
try {
  $lockResult = Invoke-WebRequest -Method GET -Uri $lockUri -Headers @{ Authorization = "Bearer $token" } `
    -MaximumRedirection 0 -TimeoutSec 30 -SkipHttpErrorCheck -ErrorAction Stop
  $lock = $lockResult.Content | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
}
catch {
  throw (New-AuditOperatorContextException -Message 'Azure did not return verifiable metadata for the selected Automation lock.')
}

if ($lockResult.StatusCode -eq 200) {
  $lockIdProperty = if ($null -ne $lock -and $lock -is [System.Management.Automation.PSCustomObject]) {
    $lock.PSObject.Properties['id']
  }
  if ($null -eq $lockIdProperty -or $lockIdProperty.Value -isnot [string] -or [string]$lockIdProperty.Value -ine $lockId) {
    throw (New-AuditOperatorContextException -Message 'Azure returned a different Automation lock than the exact selected resource.')
  }
  if (-not $lock.PSObject.Properties['properties'] -or $lock.properties -isnot [pscustomobject] -or
      -not $lock.properties.PSObject.Properties['level'] -or $lock.properties.level -isnot [string] -or
      $lock.properties.level -cne 'CanNotDelete') {
    throw (New-AuditOperatorContextException -Message 'The selected Automation lock is not the expected CanNotDelete protection.')
  }

  Assert-AuditAutomationWrite $context $subscriptionId $resourceGroupName $automationAccountName
  try {
    $removal = Invoke-WebRequest -Method DELETE -Uri $lockUri -Headers @{ Authorization = "Bearer $token" } `
      -MaximumRedirection 0 -TimeoutSec 30 -ErrorAction Stop
    if ($removal.StatusCode -notin @(200, 204)) { throw 'Lock removal did not return a terminal success status.' }
  }
  catch {
    throw (New-AuditOperatorContextException -Message 'Removal of the selected Automation lock could not be confirmed. Inspect the exact lock before retrying.')
  }
}
elseif ($lockResult.StatusCode -eq 404 -and $lock -is [pscustomobject] -and
        $lock.PSObject.Properties['error'] -and $lock.error -is [pscustomobject] -and
        $lock.error.PSObject.Properties['code'] -and $lock.error.code -is [string] -and
        $lock.error.code -cin @('LockNotFound', 'ResourceNotFound', 'ResourceGroupNotFound', 'ScopeNotFound')) {
  Assert-AuditAutomationWrite $context $subscriptionId $resourceGroupName $automationAccountName
  Write-Output 'Automation account deletion lock was not present.'
}
else {
  throw (New-AuditOperatorContextException -Message 'The selected Automation lock could not be verified. Inspect the resource before retrying teardown.')
}
