[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'Common.ps1')

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
$storedJobScheduleId = [System.Environment]::GetEnvironmentVariable('AUTOMATION_JOB_SCHEDULE_ID')
$jobScheduleId = [System.Guid]::NewGuid().ToString()

Write-Section -Message 'Managing Automation jobSchedule state'

try {
  $automationAccountExists = $false
  $showJson = & az automation account show `
    --subscription $subscriptionId `
    --resource-group $resourceGroupName `
    --name $automationAccountName `
    --only-show-errors `
    -o json 2>$null

  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($showJson)) {
    $automationAccountExists = $true
  }

  if ($automationAccountExists) {
    Write-Host 'Automation account exists. Removing lock and deleting live jobSchedules before redeploying.'

    $lockId = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/providers/Microsoft.Authorization/locks/lock-cannot-delete-automation' -f $subscriptionId, $resourceGroupName, $automationAccountName)
    & az lock delete --ids $lockId --subscription $subscriptionId --only-show-errors 2>$null | Out-Null

    $listUri = ('https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/jobSchedules?api-version=2023-11-01' -f $subscriptionId, $resourceGroupName, $automationAccountName)
    $listJson = & az rest --method GET --uri $listUri --only-show-errors -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($listJson)) {
      $jobSchedules = @(($listJson | ConvertFrom-Json).value)
      foreach ($jobSchedule in $jobSchedules) {
        if ($null -eq $jobSchedule) {
          continue
        }

        $jobScheduleIdToDelete = ''
        if ($jobSchedule.properties -and $jobSchedule.properties.jobScheduleId) {
          $jobScheduleIdToDelete = [string]$jobSchedule.properties.jobScheduleId
        }
        elseif ($jobSchedule.name) {
          $jobScheduleIdToDelete = [string]$jobSchedule.name
        }
        elseif ($jobSchedule.id) {
          $jobScheduleIdToDelete = [string]($jobSchedule.id -split '/')[-1]
        }

        if ([string]::IsNullOrWhiteSpace($jobScheduleIdToDelete)) {
          continue
        }

        Write-Host "  Deleting live jobSchedule '$jobScheduleIdToDelete'"

        $deleteUri = ('https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/jobSchedules/{3}?api-version=2023-11-01' -f $subscriptionId, $resourceGroupName, $automationAccountName, $jobScheduleIdToDelete)
        & az rest --method DELETE --uri $deleteUri --only-show-errors 2>$null | Out-Null
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($storedJobScheduleId)) {
      $jobScheduleId = $storedJobScheduleId
      Write-Host "  Reusing stored jobSchedule GUID: $jobScheduleId"
    }
    else {
      Write-Host "  Generated new jobSchedule GUID: $jobScheduleId"
    }
  }
  else {
    Write-Host "Automation account not found. Generated fresh jobSchedule GUID: $jobScheduleId"
  }
}
catch {
  Write-Warning "Could not fully manage jobSchedule state: $($_.Exception.Message)"
  Write-Host "Using fallback jobSchedule GUID: $jobScheduleId"
}

Set-AzdEnvironmentValue -Name 'AUTOMATION_JOB_SCHEDULE_ID' -Value $jobScheduleId
