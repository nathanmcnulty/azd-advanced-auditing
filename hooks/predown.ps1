[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

Write-Section -Message 'Removing the Automation account deletion lock'
Ensure-Command -Name 'az'

$azdValues = Get-AzdEnvironmentValues
$subscriptionId = Get-ValueFromEnvironment -Name 'AZURE_SUBSCRIPTION_ID' -AzdValues $azdValues
$resourceGroupName = Get-ValueFromEnvironment -Name 'AZURE_RESOURCE_GROUP' -AzdValues $azdValues
$automationAccountName = Get-ValueFromEnvironment -Name 'AUTOMATION_ACCOUNT_NAME' -AzdValues $azdValues

if ([string]::IsNullOrWhiteSpace($subscriptionId) -or [string]::IsNullOrWhiteSpace($resourceGroupName) -or [string]::IsNullOrWhiteSpace($automationAccountName)) {
  throw 'Required azd environment values were not found before teardown.'
}

$lockId = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/providers/Microsoft.Authorization/locks/lock-cannot-delete-automation' -f $subscriptionId, $resourceGroupName, $automationAccountName)
$lockExists = & az lock show --ids $lockId --subscription $subscriptionId --only-show-errors -o json 2>$null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($lockExists)) {
  & az lock delete --ids $lockId --subscription $subscriptionId --only-show-errors
  if ($LASTEXITCODE -ne 0) {
    throw "Could not remove Automation account lock '$lockId'."
  }
}
else {
  Write-Output 'Automation account deletion lock was not present.'
}
