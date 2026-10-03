[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'JobScheduleOwnership.ps1')

Write-Section -Message 'Preparing azd environment values'
Ensure-Command -Name 'az'
Ensure-Command -Name 'azd'

$names = Get-AuditTemplateNames
Set-AzdEnvironmentValue -Name 'AZURE_RESOURCE_GROUP' -Value $names.ResourceGroupName
Set-AzdEnvironmentValue -Name 'AUTOMATION_ACCOUNT_NAME' -Value $names.AutomationAccountName

$deploymentTimestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Set-AzdEnvironmentValue -Name 'DEPLOYMENT_TIMESTAMP' -Value $deploymentTimestamp

$subscriptionId = [System.Environment]::GetEnvironmentVariable('AZURE_SUBSCRIPTION_ID')
$resourceGroupName = $names.ResourceGroupName
$automationAccountName = $names.AutomationAccountName
$azdValues = Get-AzdEnvironmentValues
if ([string]::IsNullOrWhiteSpace($subscriptionId)) { throw 'AZURE_SUBSCRIPTION_ID is required.' }
$expectedAccountId = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}' -f $subscriptionId, $resourceGroupName, $automationAccountName)

Write-Section -Message 'Managing Automation jobSchedule state'

$groupExists = & az group exists --subscription $subscriptionId --name $resourceGroupName --only-show-errors -o tsv
if ($LASTEXITCODE -ne 0 -or $groupExists -notin @('true', 'false')) { throw 'Could not determine whether the target resource group exists.' }

$account = $null
$jobSchedules = @()
if ($groupExists -eq 'true') {
  $accountsJson = & az automation account list --subscription $subscriptionId --resource-group $resourceGroupName --only-show-errors -o json
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountsJson)) { throw 'Could not list Automation accounts in the target resource group.' }
  $accounts = @($accountsJson | ConvertFrom-Json -ErrorAction Stop)
  $matchingAccounts = @($accounts | Where-Object { [string]$_.name -ieq $automationAccountName })
  if ($matchingAccounts.Count -gt 1) { throw 'Automation account discovery returned duplicate target names.' }
  if ($matchingAccounts.Count -eq 1) {
    $accountJson = & az automation account show --subscription $subscriptionId --resource-group $resourceGroupName --name $automationAccountName --only-show-errors -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountJson)) { throw 'Could not inspect the existing Automation account.' }
    $account = $accountJson | ConvertFrom-Json -ErrorAction Stop
    $listUri = 'https://management.azure.com{0}/jobSchedules?api-version=2023-11-01' -f $expectedAccountId
    $listJson = & az rest --method GET --uri $listUri --only-show-errors -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($listJson)) { throw 'Could not inspect live Automation jobSchedules.' }
    $listResponse = $listJson | ConvertFrom-Json -ErrorAction Stop
    if ($listResponse.PSObject.Properties.Match('value').Count -eq 0 -or $null -eq $listResponse.value) { throw 'Automation jobSchedule listing had no value array.' }
    if ($listResponse.PSObject.Properties.Match('nextLink').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$listResponse.nextLink)) { throw 'Automation jobSchedule listing was incomplete; refusing to redeploy.' }
    $jobSchedules = @($listResponse.value)
  }
}

$ownership = Resolve-AuditJobScheduleOwnership -ExpectedAccountId $expectedAccountId -Account $account -JobSchedules $jobSchedules `
  -ReceiptAccountId (Get-ValueFromEnvironment -Name 'AUTOMATION_OWNED_ACCOUNT_ID' -AzdValues $azdValues) `
  -ReceiptPrincipalId (Get-ValueFromEnvironment -Name 'AUTOMATION_OWNED_PRINCIPAL_ID' -AzdValues $azdValues) `
  -ReceiptJobScheduleId (Get-ValueFromEnvironment -Name 'AUTOMATION_OWNED_JOB_SCHEDULE_ID' -AzdValues $azdValues) `
  -AdoptAccountId (Get-ValueFromEnvironment -Name 'AUTOMATION_ADOPT_ACCOUNT_ID' -AzdValues $azdValues) `
  -AdoptPrincipalId (Get-ValueFromEnvironment -Name 'AUTOMATION_ADOPT_PRINCIPAL_ID' -AzdValues $azdValues) `
  -AdoptJobScheduleId (Get-ValueFromEnvironment -Name 'AUTOMATION_ADOPT_JOB_SCHEDULE_ID' -AzdValues $azdValues)

if (-not [string]::IsNullOrWhiteSpace($ownership.OwnedJobScheduleId)) {
  Write-Host "Existing template jobSchedule '$($ownership.OwnedJobScheduleId)' verified. Its linkage remains intact while ARM redeploys."
}
Set-AzdEnvironmentValue -Name 'AUTOMATION_JOB_SCHEDULE_ID' -Value $ownership.JobScheduleId
