#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Local operator-only adaptation of Assert-SecurityAzureTarget from the
# azd-reference security-automation-runtime. Never change the CLI default.
function New-AuditTargetGuardException {
  param([Parameter(Mandatory = $true)][string]$Message)

  $exception = [InvalidOperationException]::new($Message)
  $exception.Data['AuditTargetGuard'] = $true
  return $exception
}

function Assert-AuditOperatorSelectors {
  param([string]$SubscriptionId, [string]$TenantId)

  foreach ($value in @($SubscriptionId, $TenantId)) {
    $parsed = [guid]::Empty
    if ($value -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or
        -not [guid]::TryParseExact($value, 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty) {
      throw (New-AuditTargetGuardException -Message 'Explicit nonempty AZURE_SUBSCRIPTION_ID and AZURE_TENANT_ID GUIDs are required.')
    }
  }
}

function Get-AuditScopedAccessToken {
  param(
    [Parameter(Mandatory = $true)][string]$ResourceUrl,
    [Parameter(Mandatory = $true)]$Target
  )

  $tokenUnavailable = $false
  try {
    Assert-AuditOperatorSelectors -SubscriptionId $Target.SubscriptionId -TenantId $Target.TenantId
    # Azure CLI does not allow --tenant with --subscription. Scope by subscription
    # and validate both selectors in the returned metadata instead.
    try {
      $raw = & az account get-access-token --subscription $Target.SubscriptionId --resource $ResourceUrl --output json --only-show-errors 2>$null
    }
    catch {
      $tokenUnavailable = $true
      throw
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($raw -join "`n"))) {
      $tokenUnavailable = $true
      throw 'Token acquisition failed.'
    }
    $result = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
    if ($result.subscription -isnot [string] -or $result.subscription -ine $Target.SubscriptionId -or
        $result.tenant -isnot [string] -or $result.tenant -ine $Target.TenantId -or
        $result.accessToken -isnot [string] -or [string]::IsNullOrWhiteSpace($result.accessToken)) {
      throw 'Token target metadata is invalid.'
    }
    return $result.accessToken
  }
  catch {
    # Provider errors can contain authentication material. Do not forward them.
    $exception = New-AuditTargetGuardException -Message 'Could not acquire an Azure CLI token matching the explicit subscription and tenant. Verify the selected account using normal browser or broker authentication.'
    if ($tokenUnavailable) { $exception.Data['AuditTokenUnavailable'] = $true }
    throw $exception
  }
}

function Assert-AuditOperatorTarget {
  param([string]$SubscriptionId)

  try {
    Ensure-Command -Name 'az'
    $azdValues = Get-AzdEnvironmentValues
  }
  catch {
    throw (New-AuditTargetGuardException -Message 'Could not inspect the explicit operator target in the selected azd environment.')
  }
  $expectedSubscriptionId = Get-ValueFromEnvironment -Name 'AZURE_SUBSCRIPTION_ID' -AzdValues $azdValues
  $expectedTenantId = Get-ValueFromEnvironment -Name 'AZURE_TENANT_ID' -AzdValues $azdValues
  Assert-AuditOperatorSelectors -SubscriptionId $expectedSubscriptionId -TenantId $expectedTenantId

  foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID')) {
    $selectedValue = Get-ValueFromEnvironment -Name $name -AzdValues $azdValues
    if ($azdValues.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace([string]$azdValues[$name]) -and
        [string]$azdValues[$name] -ine $selectedValue) {
      throw (New-AuditTargetGuardException -Message 'Process and selected azd environment Azure selectors disagree.')
    }
  }
  if ($PSBoundParameters.ContainsKey('SubscriptionId') -and $SubscriptionId -ine $expectedSubscriptionId) {
    throw (New-AuditTargetGuardException -Message 'The requested subscription does not match the selected azd environment.')
  }

  $pinnedVariable = Get-Variable -Name AuditOperatorTarget -Scope Script -ErrorAction SilentlyContinue
  if ($pinnedVariable -and ($pinnedVariable.Value.SubscriptionId -ine $expectedSubscriptionId -or
      $pinnedVariable.Value.TenantId -ine $expectedTenantId)) {
    throw (New-AuditTargetGuardException -Message 'The selected operator subscription or tenant changed during this operation.')
  }

  try {
    $raw = & az account show --subscription $expectedSubscriptionId --output json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Account lookup failed.' }
    $account = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
    if ($account.id -isnot [string] -or $account.id -ine $expectedSubscriptionId -or
        $account.tenantId -isnot [string] -or $account.tenantId -ine $expectedTenantId -or
        $account.environmentName -isnot [string] -or $account.environmentName -cne 'AzureCloud' -or
        $account.user.type -isnot [string] -or $account.user.type -ine 'user' -or
        $account.user.name -isnot [string] -or [string]::IsNullOrWhiteSpace($account.user.name)) {
      throw 'Account target or operator identity is invalid.'
    }
    if ($pinnedVariable -and $pinnedVariable.Value.UserPrincipalName -ine $account.user.name) {
      throw 'Operator identity changed.'
    }
    $target = [pscustomobject]@{
      SubscriptionId = $expectedSubscriptionId
      TenantId = $expectedTenantId
      UserPrincipalName = $account.user.name
    }
    $token = Get-AuditScopedAccessToken -ResourceUrl 'https://management.azure.com/' -Target $target
    $subscription = Invoke-RestMethod -Method Get `
      -Uri "https://management.azure.com/subscriptions/${expectedSubscriptionId}?api-version=2022-12-01" `
      -Headers @{ Authorization = "Bearer $token" } -MaximumRedirection 0 -TimeoutSec 30
    if ($subscription.id -isnot [string] -or $subscription.id -ine "/subscriptions/$expectedSubscriptionId" -or
        $subscription.subscriptionId -isnot [string] -or $subscription.subscriptionId -ine $expectedSubscriptionId -or
        $subscription.tenantId -isnot [string] -or $subscription.tenantId -ine $expectedTenantId -or
        $subscription.state -isnot [string] -or $subscription.state -cne 'Enabled') {
      throw 'Subscription target is invalid or not Enabled.'
    }
  }
  catch {
    throw (New-AuditTargetGuardException -Message 'Unable to verify the explicit Azure public-cloud operator target and current Enabled subscription state.')
  }

  # Pin only after successful live validation. Never reset when Common is sourced
  # again, and do not expose the mutable pinned object to callers.
  if (-not $pinnedVariable) {
    $script:AuditOperatorTarget = [pscustomobject]@{
      SubscriptionId = $target.SubscriptionId
      TenantId = $target.TenantId
      UserPrincipalName = $target.UserPrincipalName
    }
  }
  return $target
}
