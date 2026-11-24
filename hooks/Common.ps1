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

function New-AuditOperatorContextException {
  param([Parameter(Mandatory = $true)][string]$Message)

  $exception = [System.InvalidOperationException]::new($Message)
  $exception.Data['AuditOperatorContext'] = $true
  return $exception
}

function Test-AuditOperatorContextException {
  param([Parameter(Mandatory = $true)][object]$ErrorRecord)

  $exception = $ErrorRecord
  if ($ErrorRecord.PSObject.Properties.Match('Exception').Count -gt 0) {
    $exception = $ErrorRecord.Exception
  }

  while ($null -ne $exception) {
    if ($exception.Data -and $exception.Data['AuditOperatorContext'] -eq $true) {
      return $true
    }
    $exception = $exception.InnerException
  }

  return $false
}

function Get-AuditOperatorTargetSelector {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][hashtable]$AzdValues
  )

  $upperName = $Name.ToUpperInvariant()
  $environmentValue = ''
  if ($AzdValues.ContainsKey($upperName)) {
    $environmentValue = ([string]$AzdValues[$upperName]).Trim()
  }
  $processValue = ([System.Environment]::GetEnvironmentVariable($Name) ?? '').Trim()

  if (-not [string]::IsNullOrWhiteSpace($environmentValue) -and
      -not [string]::IsNullOrWhiteSpace($processValue) -and
      -not [string]::Equals($environmentValue, $processValue, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw (New-AuditOperatorContextException -Message "The process and selected azd values for '$Name' do not match.")
  }

  $value = if (-not [string]::IsNullOrWhiteSpace($processValue)) { $processValue } else { $environmentValue }
  $parsedId = [guid]::Empty
  if ([string]::IsNullOrWhiteSpace($value) -or -not [guid]::TryParse($value, [ref]$parsedId)) {
    throw (New-AuditOperatorContextException -Message "An explicit GUID for '$Name' is required in the selected azd environment or process environment.")
  }

  return $parsedId.ToString()
}

function Get-AuditOperatorAccount {
  param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$TenantId
  )

  $parsedSubscriptionId = [guid]::Empty
  $parsedTenantId = [guid]::Empty
  if (-not [guid]::TryParse($SubscriptionId, [ref]$parsedSubscriptionId) -or
      -not [guid]::TryParse($TenantId, [ref]$parsedTenantId)) {
    throw (New-AuditOperatorContextException -Message 'Explicit Azure CLI subscription and tenant selectors must be GUIDs.')
  }
  $SubscriptionId = $parsedSubscriptionId.ToString()
  $TenantId = $parsedTenantId.ToString()

  try {
    Ensure-Command -Name 'az'
    $accountJson = & az account show --subscription $SubscriptionId --only-show-errors --output json 2>$null
  }
  catch {
    throw (New-AuditOperatorContextException -Message 'Could not read the explicitly selected Azure CLI account.')
  }

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountJson)) {
    throw (New-AuditOperatorContextException -Message 'Could not read the explicitly selected Azure CLI account.')
  }

  try {
    $account = $accountJson | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
  }
  catch {
    throw (New-AuditOperatorContextException -Message 'Azure CLI returned malformed selected-account metadata.')
  }

  if ($null -eq $account -or $account -isnot [System.Management.Automation.PSCustomObject]) {
    throw (New-AuditOperatorContextException -Message 'Azure CLI returned malformed selected-account metadata.')
  }

  $accountIdProperty = $account.PSObject.Properties['id']
  $tenantIdProperty = $account.PSObject.Properties['tenantId']
  $userProperty = $account.PSObject.Properties['user']
  $userNameProperty = if ($null -ne $userProperty -and
      $userProperty.Value -is [System.Management.Automation.PSCustomObject]) {
    $userProperty.Value.PSObject.Properties['name']
  }
  if ($null -eq $accountIdProperty -or $null -eq $tenantIdProperty -or $null -eq $userNameProperty -or
      $accountIdProperty.Value -isnot [string] -or $tenantIdProperty.Value -isnot [string] -or
      $userNameProperty.Value -isnot [string] -or
      [string]$accountIdProperty.Value -ine $SubscriptionId -or [string]$tenantIdProperty.Value -ine $TenantId -or
      [string]::IsNullOrWhiteSpace($userNameProperty.Value)) {
    throw (New-AuditOperatorContextException -Message 'Azure CLI account metadata does not match the explicit subscription and tenant selectors.')
  }

  return $account
}

function Get-AuditScopedAccessToken {
  param(
    [Parameter(Mandatory = $true)][string]$ResourceUrl,
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$TenantId
  )

  $parsedSubscriptionId = [guid]::Empty
  $parsedTenantId = [guid]::Empty
  if (-not [guid]::TryParse($SubscriptionId, [ref]$parsedSubscriptionId) -or
      -not [guid]::TryParse($TenantId, [ref]$parsedTenantId)) {
    throw (New-AuditOperatorContextException -Message 'Explicit Azure CLI subscription and tenant selectors must be GUIDs.')
  }
  $SubscriptionId = $parsedSubscriptionId.ToString()
  $TenantId = $parsedTenantId.ToString()
  if ($ResourceUrl -notin @(
      'https://management.azure.com',
      'https://graph.microsoft.com',
      'https://outlook.office365.com',
      'https://ps.compliance.protection.outlook.com'
    )) {
    throw (New-AuditOperatorContextException -Message 'The requested Azure CLI token audience is not supported by this hook.')
  }

  # Azure CLI resolves the account and tenant from this explicit subscription.
  $null = Get-AuditOperatorAccount -SubscriptionId $SubscriptionId -TenantId $TenantId

  try {
    Ensure-Command -Name 'az'
    $tokenArguments = @('account', 'get-access-token', '--subscription', $SubscriptionId)
    $tokenArguments += @('--resource', $ResourceUrl, '--only-show-errors', '--output', 'json')
    $tokenJson = & az @tokenArguments 2>$null
  }
  catch {
    throw (New-AuditOperatorContextException -Message "Could not acquire a scoped Azure CLI token for '$ResourceUrl'.")
  }

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tokenJson)) {
    throw (New-AuditOperatorContextException -Message "Could not acquire a scoped Azure CLI token for '$ResourceUrl'.")
  }

  try {
    $tokenResponse = $tokenJson | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
  }
  catch {
    throw (New-AuditOperatorContextException -Message "Azure CLI returned malformed token metadata for '$ResourceUrl'.")
  }

  if ($null -eq $tokenResponse -or $tokenResponse -isnot [System.Management.Automation.PSCustomObject]) {
    throw (New-AuditOperatorContextException -Message "Azure CLI returned malformed token metadata for '$ResourceUrl'.")
  }

  $accessTokenProperty = $tokenResponse.PSObject.Properties['accessToken']
  $subscriptionProperty = $tokenResponse.PSObject.Properties['subscription']
  $tenantProperty = $tokenResponse.PSObject.Properties['tenant']
  $invalidSubscriptionMetadata = $null -eq $subscriptionProperty -or
    $subscriptionProperty.Value -isnot [string] -or
    [string]$subscriptionProperty.Value -ine $SubscriptionId
  if ($null -eq $accessTokenProperty -or $null -eq $tenantProperty -or
      $accessTokenProperty.Value -isnot [string] -or $tenantProperty.Value -isnot [string] -or
      [string]::IsNullOrWhiteSpace($accessTokenProperty.Value) -or
      [string]$tenantProperty.Value -ine $TenantId -or $invalidSubscriptionMetadata) {
    throw (New-AuditOperatorContextException -Message "Azure CLI token metadata does not match the explicit subscription and tenant selectors for '$ResourceUrl'.")
  }

  return [string]$accessTokenProperty.Value
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
  if ($LASTEXITCODE -ne 0) {
    throw "Could not persist azd environment value '$Name'."
  }
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
    [Parameter(Mandatory = $true)][string]$TenantId,
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

  $armToken = Get-AuditScopedAccessToken `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -ResourceUrl 'https://management.azure.com'

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
  if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect Automation runbook '$RunbookName' before publishing."
  }

  & az automation runbook replace-content `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --automation-account-name $AutomationAccountName `
    --name $RunbookName `
    --content "@$FilePath" `
    --only-show-errors `
    -o none
  if ($LASTEXITCODE -ne 0) {
    throw "Could not replace content for Automation runbook '$RunbookName'."
  }

  & az automation runbook publish `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --automation-account-name $AutomationAccountName `
    --name $RunbookName `
    --only-show-errors `
    -o none
  if ($LASTEXITCODE -ne 0) {
    throw "Could not publish Automation runbook '$RunbookName'."
  }
}

function Write-AutomationJobStreams {
  param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [Parameter(Mandatory = $true)][string]$AutomationAccountName,
    [Parameter(Mandatory = $true)][string]$JobId
  )

  $streamsUri = ('https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}/jobs/{3}/streams?api-version=2023-11-01' -f $SubscriptionId, $ResourceGroupName, $AutomationAccountName, $JobId)

  try {
    $streamResponse = & az rest --method GET --uri $streamsUri --only-show-errors -o json | ConvertFrom-Json
    foreach ($stream in @($streamResponse.value)) {
      if ($null -eq $stream) {
        continue
      }

      $streamType = if ($stream.properties.streamType) { [string]$stream.properties.streamType } else { 'Stream' }
      $summary = if ($stream.properties.summary) { [string]$stream.properties.summary } else { '' }
      if (-not [string]::IsNullOrWhiteSpace($summary)) {
        Write-Warning ("[{0}] {1}" -f $streamType, $summary)
      }
    }
  }
  catch {
    Write-Warning "Could not retrieve output streams for Automation job '$JobId': $($_.Exception.Message)"
  }
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
        Write-AutomationJobStreams `
          -SubscriptionId $SubscriptionId `
          -ResourceGroupName $ResourceGroupName `
          -AutomationAccountName $AutomationAccountName `
          -JobId $JobId

        $exceptionMessage = ''
        if ($job.exception) {
          $exceptionMessage = [string]$job.exception
        }
        elseif ($job.properties -and $job.properties.exception) {
          $exceptionMessage = [string]$job.properties.exception
        }

        $detail = if ([string]::IsNullOrWhiteSpace($exceptionMessage)) { '' } else { " $exceptionMessage" }
        throw "Automation job '$JobId' finished with status '$status'.$detail"
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
