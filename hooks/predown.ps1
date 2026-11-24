[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

Write-Section -Message 'Removing the Automation account deletion lock'
Ensure-Command -Name 'az'

$environmentName = Get-AuditHookEnvironmentName
$azdValues = Get-AuditPinnedAzdEnvironmentValues -EnvironmentName $environmentName -RequireResourceValues
$target = Assert-AuditOperatorSubscriptionEnabled -AzdValues $azdValues
$subscriptionId = $target.SubscriptionId
$resourceGroupName = [string]$azdValues['AZURE_RESOURCE_GROUP']
$automationAccountName = [string]$azdValues['AUTOMATION_ACCOUNT_NAME']

if ([string]::IsNullOrWhiteSpace($subscriptionId) -or [string]::IsNullOrWhiteSpace($resourceGroupName) -or [string]::IsNullOrWhiteSpace($automationAccountName)) {
  throw 'Required azd environment values were not found before teardown.'
}

$lockId = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/providers/Microsoft.Authorization/locks/lock-cannot-delete-automation' -f $subscriptionId, $resourceGroupName, $automationAccountName)
$lockExists = & az lock show --ids $lockId --subscription $subscriptionId --only-show-errors -o json 2>$null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($lockExists)) {
  try {
    $lock = $lockExists | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
  }
  catch {
    throw (New-AuditOperatorContextException -Message 'Azure returned malformed metadata for the selected Automation lock.')
  }

  $lockIdProperty = if ($null -ne $lock -and $lock -is [System.Management.Automation.PSCustomObject]) {
    $lock.PSObject.Properties['id']
  }
  if ($null -eq $lockIdProperty -or $lockIdProperty.Value -isnot [string] -or [string]$lockIdProperty.Value -ine $lockId) {
    throw (New-AuditOperatorContextException -Message 'Azure returned a different Automation lock than the exact selected resource.')
  }

  $finalAzdValues = Get-AuditPinnedAzdEnvironmentValues -EnvironmentName $environmentName -RequireResourceValues
  $deleteTarget = Assert-AuditOperatorSubscriptionEnabled -AzdValues $finalAzdValues
  if ($deleteTarget.SubscriptionId -ine $target.SubscriptionId -or
      $deleteTarget.TenantId -ine $target.TenantId -or
      $deleteTarget.OperatorIdentity -ine $target.OperatorIdentity -or
      [string]$finalAzdValues['AZURE_RESOURCE_GROUP'] -ine $resourceGroupName -or
      [string]$finalAzdValues['AUTOMATION_ACCOUNT_NAME'] -ine $automationAccountName) {
    throw (New-AuditOperatorContextException -Message 'The selected azd environment, Azure target, CLI operator, or Automation resource changed before the lock could be removed.')
  }
  & az lock delete --ids $lockId --subscription $subscriptionId --only-show-errors
  if ($LASTEXITCODE -ne 0) {
    throw "Could not remove Automation account lock '$lockId'."
  }
}
else {
  Write-Output 'Automation account deletion lock was not present.'
}
