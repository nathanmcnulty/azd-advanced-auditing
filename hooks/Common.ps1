Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section {
  param([Parameter(Mandatory = $true)][string]$Message)

  Write-Host ''
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Ensure-Command {
  param([Parameter(Mandatory = $true)][string]$Name)

  if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' was not found in PATH."
  }
}

function Ensure-PowerShellModule {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $false)][string]$MinimumVersion
  )

  $available = @(Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending)
  $minimum = $null
  if (-not [string]::IsNullOrWhiteSpace($MinimumVersion)) {
    $minimum = [version]$MinimumVersion
  }

  if ($available.Count -gt 0) {
    if ($null -eq $minimum) {
      return
    }

    $versionMatch = $available | Where-Object { $_.Version -ge $minimum } | Select-Object -First 1
    if ($versionMatch) {
      return
    }
  }

  $installParams = @{
    Name         = $Name
    Scope        = 'CurrentUser'
    Force        = $true
    AllowClobber = $true
    Repository   = 'PSGallery'
  }

  if ($null -ne $minimum) {
    $installParams['MinimumVersion'] = $minimum
  }

  Install-Module @installParams -WarningAction SilentlyContinue

  $installed = @(Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -ge $minimum })
  if ($null -ne $minimum -and $installed.Count -eq 0) {
    throw "PowerShell module '$Name' version $MinimumVersion or newer could not be installed."
  }
}

function Get-TemplateRoot {
  return (Split-Path -Path $PSScriptRoot -Parent)
}

function Get-RunbooksPath {
  return (Join-Path -Path (Get-TemplateRoot) -ChildPath 'runbooks')
}

function Get-AzdEnvironmentValues {
  Ensure-Command -Name 'azd'

  $values = @{}
  $lines = & azd env get-values --no-prompt 2>$null
  foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    if ($line -match '^(?:export\s+)?(?<name>[A-Za-z0-9_]+)=(?<value>.*)$') {
      $name = $matches['name'].ToUpperInvariant()
      $value = $matches['value'].Trim()

      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
      }

      $values[$name] = $value
    }
  }

  return $values
}

function Get-ValueFromEnvironment {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $false)][hashtable]$AzdValues
  )

  $processValue = [System.Environment]::GetEnvironmentVariable($Name)
  if (-not [string]::IsNullOrWhiteSpace($processValue)) {
    return $processValue
  }

  $upperName = $Name.ToUpperInvariant()
  if ($AzdValues -and $AzdValues.ContainsKey($upperName) -and -not [string]::IsNullOrWhiteSpace([string]$AzdValues[$upperName])) {
    return [string]$AzdValues[$upperName]
  }

  return ''
}

function Set-AzdEnvironmentValue {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Value
  )

  Ensure-Command -Name 'azd'
  & azd env set $Name $Value --no-prompt | Out-Null
  [System.Environment]::SetEnvironmentVariable($Name, $Value)
}

function Get-EnvironmentSuffix {
  param([Parameter(Mandatory = $true)][string]$EnvironmentName)

  $normalized = ($EnvironmentName.Trim().ToLowerInvariant() -replace '[^a-z0-9-]', '')
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return 'audit'
  }

  if ($normalized.Length -gt 24) {
    return $normalized.Substring($normalized.Length - 24)
  }

  return $normalized
}

function Get-AuditTemplateNames {
  $azdValues = Get-AzdEnvironmentValues
  $environmentName = [System.Environment]::GetEnvironmentVariable('AZURE_ENV_NAME')
  if ([string]::IsNullOrWhiteSpace($environmentName)) {
    if ($azdValues.ContainsKey('AZURE_ENV_NAME')) {
      $environmentName = [string]$azdValues['AZURE_ENV_NAME']
    }
  }

  if ([string]::IsNullOrWhiteSpace($environmentName)) {
    throw 'AZURE_ENV_NAME is not set.'
  }

  $suffix = Get-EnvironmentSuffix -EnvironmentName $environmentName
  $automationSuffix = (($environmentName.Trim().ToLowerInvariant()) -replace '[^a-z0-9]', '')
  if ([string]::IsNullOrWhiteSpace($automationSuffix)) {
    $automationSuffix = 'audit'
  }

  if ($automationSuffix.Length -gt 24) {
    $automationSuffix = $automationSuffix.Substring($automationSuffix.Length - 24)
  }

  $resourceGroupName = Get-ValueFromEnvironment -Name 'AZURE_RESOURCE_GROUP' -AzdValues $azdValues
  if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
    $resourceGroupName = "rg-$environmentName"
  }

  return [pscustomobject]@{
    ResourceGroupName    = $resourceGroupName
    AutomationAccountName = "aaaudit$automationSuffix"
  }
}

function ConvertTo-AutomationVariableLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)

  return ('"{0}"' -f ($Value.Replace('\', '\\').Replace('"', '\"')))
}

function Set-AutomationVariableValue {
  param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [Parameter(Mandatory = $true)][string]$AutomationAccountName,
    [Parameter(Mandatory = $true)][string]$VariableName,
    [Parameter(Mandatory = $true)][string]$Value
  )

  $uri = ('https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/variables/{3}?api-version=2023-11-01' -f $SubscriptionId, $ResourceGroupName, $AutomationAccountName, $VariableName)
  $payload = @{
    properties = @{
      description = "Updated by postprovision for $VariableName"
      isEncrypted = $false
      value       = (ConvertTo-AutomationVariableLiteral -Value $Value)
    }
  } | ConvertTo-Json -Depth 5 -Compress

  $armToken = & az account get-access-token --resource https://management.azure.com --query accessToken -o tsv --only-show-errors
  if ([string]::IsNullOrWhiteSpace($armToken)) {
    throw 'Could not acquire an Azure Resource Manager access token from Azure CLI.'
  }

  Invoke-RestMethod `
    -Method PUT `
    -Uri $uri `
    -Headers @{ Authorization = "Bearer $($armToken.Trim())" } `
    -ContentType 'application/json' `
    -Body $payload | Out-Null
}

function Publish-AutomationRunbookContent {
  param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [Parameter(Mandatory = $true)][string]$AutomationAccountName,
    [Parameter(Mandatory = $true)][string]$RunbookName,
    [Parameter(Mandatory = $true)][string]$FilePath
  )

  if (-not (Test-Path -Path $FilePath)) {
    throw "Runbook file '$FilePath' does not exist."
  }

  & az automation runbook show `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --automation-account-name $AutomationAccountName `
    --name $RunbookName `
    --only-show-errors `
    -o none

  & az automation runbook replace-content `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --automation-account-name $AutomationAccountName `
    --name $RunbookName `
    --content "@$FilePath" `
    --only-show-errors `
    -o none

  & az automation runbook publish `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --automation-account-name $AutomationAccountName `
    --name $RunbookName `
    --only-show-errors `
    -o none
}

function Wait-AutomationJob {
  param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [Parameter(Mandatory = $true)][string]$AutomationAccountName,
    [Parameter(Mandatory = $true)][string]$JobId,
    [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 900
  )

  $terminalStates = @('Completed', 'Failed', 'Stopped', 'Suspended')
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

  do {
    Start-Sleep -Seconds 10

    $job = & az automation job show `
      --subscription $SubscriptionId `
      --resource-group $ResourceGroupName `
      --automation-account-name $AutomationAccountName `
      --name $JobId `
      --only-show-errors `
      -o json | ConvertFrom-Json

    $status = ''
    if ($job.status) {
      $status = [string]$job.status
    }
    elseif ($job.properties -and $job.properties.status) {
      $status = [string]$job.properties.status
    }

    Write-Host "  Job $JobId status: $status"

    if ($terminalStates -contains $status) {
      if ($status -ne 'Completed') {
        throw "Automation job '$JobId' finished with status '$status'."
      }

      return $job
    }
  } while ((Get-Date) -lt $deadline)

  throw "Timed out waiting for automation job '$JobId' to complete."
}

function Start-AutomationRunbookAndWait {
  param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [Parameter(Mandatory = $true)][string]$AutomationAccountName,
    [Parameter(Mandatory = $true)][string]$RunbookName,
    [Parameter(Mandatory = $false)][hashtable]$Parameters
  )

  $commandArgs = @(
    'automation', 'runbook', 'start',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--automation-account-name', $AutomationAccountName,
    '--name', $RunbookName,
    '--only-show-errors',
    '-o', 'json'
  )

  if ($Parameters -and $Parameters.Count -gt 0) {
    $commandArgs += '--parameters'
    foreach ($key in $Parameters.Keys) {
      $commandArgs += ('{0}={1}' -f $key, $Parameters[$key])
    }
  }

  $job = & az @commandArgs | ConvertFrom-Json

  $jobId = ''
  if ($job.jobId) {
    $jobId = [string]$job.jobId
  }
  elseif ($job.id) {
    $jobId = [string]$job.id
  }
  elseif ($job.name) {
    $jobId = [string]$job.name
  }

  if ([string]::IsNullOrWhiteSpace($jobId)) {
    throw "Could not determine job id when starting runbook '$RunbookName'."
  }

  return (Wait-AutomationJob -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -JobId $jobId)
}
