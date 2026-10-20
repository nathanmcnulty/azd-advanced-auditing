#Requires -Version 7.6
Describe 'Auditing Common operator integration' {
BeforeAll {
  $script:repoRoot = Split-Path $PSScriptRoot -Parent
  $script:selectorNames = @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_ENV_NAME', 'AZURE_RESOURCE_GROUP', 'AUTOMATION_ACCOUNT_NAME', 'DEPLOYMENT_TIMESTAMP', 'AUTOMATION_JOB_SCHEDULE_ID')
  $script:previousEnvironment = @{}
  foreach ($name in $script:selectorNames) {
    $script:previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
  }
  . "$script:repoRoot/hooks/Common.ps1"
  $tokens = $null
  $parseErrors = $null
  $postprovision = [Management.Automation.Language.Parser]::ParseFile("$script:repoRoot/hooks/postprovision.ps1", [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count) { throw 'Could not parse the actual postprovision helpers.' }
  foreach ($functionName in @('Get-AzCliAccessToken', 'Invoke-GraphRest')) {
    $definition = $postprovision.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
    if (-not $definition) { throw "Could not find actual helper '$functionName'." }
    . ([scriptblock]::Create($definition.Extent.Text))
  }

  function az {
    $arguments = @($args)
    $fixture = $global:AuditOperatorFixture
    $fixture.Calls.Add(($arguments -join ' '))
    $global:LASTEXITCODE = 0
    $command = $arguments[0..2] -join ' '
    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'set') { throw 'Offline fixture forbids changing the Azure CLI default.' }
    $subscriptionIndex = [array]::IndexOf($arguments, '--subscription')
    if ($subscriptionIndex -lt 0 -or $arguments[$subscriptionIndex + 1] -ne $fixture.SelectedSubscription) {
      throw 'Offline fixture requires the exact selected subscription on every Azure CLI command.'
    }
    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'show') {
      $global:LASTEXITCODE = $fixture.AccountExit
      return $fixture.Account | ConvertTo-Json -Depth 8 -Compress
    }
    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'get-access-token') {
      $global:LASTEXITCODE = $fixture.TokenExit
      if ($fixture.BadTokenJson) { return 'TOKEN-SECRET-SENTINEL malformed json' }
      $resourceIndex = [array]::IndexOf($arguments, '--resource')
      if ($resourceIndex -lt 0) { throw 'Offline fixture requires an explicit token resource.' }
      if ($arguments[$resourceIndex + 1] -eq 'https://graph.microsoft.com') {
        $resourceToken = $fixture.Token.Clone()
        switch ($fixture.ResourceTokenMode) {
          'wrong-tenant' { $resourceToken.tenant = '33333333-3333-3333-3333-333333333333' }
          'wrong-subscription' { $resourceToken.subscription = '33333333-3333-3333-3333-333333333333' }
          'malformed' { return 'TOKEN-SECRET-SENTINEL malformed json' }
          'unavailable' { $global:LASTEXITCODE = 7; return }
          'empty' { return }
        }
        if ($fixture.DriftActorAfterResourceToken) { $fixture.Account.user.name = 'other@example.test' }
        return $resourceToken | ConvertTo-Json -Depth 8 -Compress
      }
      return $fixture.Token | ConvertTo-Json -Depth 8 -Compress
    }
    switch ($command) {
      'automation runbook show' { return }
      'automation runbook replace-content' {
        $fixture.Writes.Add('replace-content')
        if ($fixture.DisableAfterReplace) { $fixture.Subscription.state = 'Disabled' }
        return
      }
      'automation runbook publish' { $fixture.Writes.Add('publish'); return }
      'automation runbook start' { $fixture.Writes.Add('start'); return '{"jobId":"fixture-job"}' }
      'automation job show' { return '{"status":"Completed"}' }
      'group exists --subscription' { return 'false' }
      'lock show --ids' {
        if ($fixture.DisableAfterLockRead) { $fixture.Subscription.state = 'Disabled' }
        if ($fixture.LockAbsent) { $global:LASTEXITCODE = 3; return }
        return '{"id":"fixture-lock"}'
      }
      'lock delete --ids' { $fixture.Writes.Add('lock-delete'); return }
      default { throw "Offline fixture forbids unexpected Azure CLI command: $command" }
    }
  }

  function azd {
    $fixture = $global:AuditOperatorFixture
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'env' -and $args[1] -eq 'get-values') {
      $global:LASTEXITCODE = $fixture.AzdExit
      foreach ($key in $fixture.AzdValues.Keys) { '{0}="{1}"' -f $key, $fixture.AzdValues[$key] }
      return
    }
    if ($args[0] -eq 'env' -and $args[1] -eq 'set') {
      $fixture.Writes.Add("env-set:$($args[2])")
      $fixture.AzdValues[$args[2]] = $args[3]
      if ($fixture.DisableAfterEnvironmentSet) { $fixture.Subscription.state = 'Disabled' }
      return
    }
    throw 'Offline fixture forbids unexpected azd commands.'
  }

  function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body, $MaximumRedirection, $TimeoutSec)
    $fixture = $global:AuditOperatorFixture
    if ($Headers.Authorization -cne 'Bearer TOKEN-SECRET-SENTINEL' -or $MaximumRedirection -ne 0 -or $TimeoutSec -ne 30) {
      throw 'Offline fixture requires scoped credentials, bounded timeout, and no redirects.'
    }
    if ($Method -ieq 'GET' -and $Uri -ceq "https://management.azure.com/subscriptions/$($fixture.SelectedSubscription)?api-version=2022-12-01") {
      $fixture.LiveReads++
      if ($fixture.LiveReadFailure) { throw 'PROVIDER-SECRET-SENTINEL' }
      if ($fixture.DisableAtLiveRead -eq $fixture.LiveReads) { $fixture.Subscription.state = 'Disabled' }
      return [pscustomobject]$fixture.Subscription
    }
    if ($Method -ieq 'PUT' -and $Uri -like "https://management.azure.com/subscriptions/$($fixture.SelectedSubscription)/resourceGroups/fixture-rg/providers/Microsoft.Automation/automationAccounts/fixture-audit/variables/*") {
      $fixture.Writes.Add('variable-put')
      return
    }
    if ($Uri -ceq 'https://graph.microsoft.com/v1.0/servicePrincipals/fixture/appRoleAssignments' -and $Method -ieq 'POST') {
      $fixture.Writes.Add('graph-post')
      return [pscustomobject]@{ id = 'fixture-assignment' }
    }
    throw 'Offline fixture forbids unexpected network requests.'
  }
  function Invoke-WebRequest { throw 'Offline fixture forbids network fallback.' }
  function Start-Sleep { param($Seconds) }
}

BeforeEach {
  Remove-Variable -Name AuditOperatorTarget -Scope Script -ErrorAction SilentlyContinue
  foreach ($name in $script:selectorNames) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
  $subscription = '11111111-1111-1111-1111-111111111111'
  $tenant = '22222222-2222-2222-2222-222222222222'
  $global:AuditOperatorFixture = @{
    SelectedSubscription = $subscription
    DefaultSubscription = '99999999-9999-9999-9999-999999999999'
    AzdValues = @{ AZURE_SUBSCRIPTION_ID = $subscription; AZURE_TENANT_ID = $tenant; AZURE_ENV_NAME = 'fixture'; AZURE_RESOURCE_GROUP = 'fixture-rg'; AUTOMATION_ACCOUNT_NAME = 'fixture-audit' }
    Account = @{ id = $subscription; tenantId = $tenant; environmentName = 'AzureCloud'; user = @{ type = 'user'; name = 'operator@example.test' } }
    Token = @{ subscription = $subscription; tenant = $tenant; accessToken = 'TOKEN-SECRET-SENTINEL' }
    Subscription = @{ id = "/subscriptions/$subscription"; subscriptionId = $subscription; tenantId = $tenant; state = 'Enabled' }
    Calls = [Collections.Generic.List[string]]::new()
    Writes = [Collections.Generic.List[string]]::new()
    LiveReads = 0
    AzdExit = 0
    AccountExit = 0
    TokenExit = 0
    BadTokenJson = $false
    LiveReadFailure = $false
    DisableAtLiveRead = 0
    DisableAfterReplace = $false
    DisableAfterEnvironmentSet = $false
    DisableAfterLockRead = $false
    LockAbsent = $false
    ResourceTokenMode = 'valid'
    DriftActorAfterResourceToken = $false
  }
  $script:runbookPath = Join-Path $TestDrive 'fixture-runbook.ps1'
  Set-Content -LiteralPath $script:runbookPath -Value 'Write-Output "offline fixture"'
  $script:commonArguments = @{ SubscriptionId = $subscription; ResourceGroupName = 'fixture-rg'; AutomationAccountName = 'fixture-audit' }
}

Describe 'Explicit auditing operator target' {
  It 'uses selected azd values and fresh scoped metadata without changing the CLI default' {
    $first = Assert-AuditOperatorTarget
    $second = Assert-AuditOperatorTarget
    $first.SubscriptionId | Should -Be $global:AuditOperatorFixture.SelectedSubscription
    $first.TenantId | Should -Be $global:AuditOperatorFixture.AzdValues.AZURE_TENANT_ID
    $first.UserPrincipalName | Should -Be 'operator@example.test'
    $second.SubscriptionId | Should -Be $first.SubscriptionId
    $global:AuditOperatorFixture.LiveReads | Should -Be 2
    $global:AuditOperatorFixture.Calls.Count | Should -Be 4
    @($global:AuditOperatorFixture.Calls | Where-Object { $_ -like 'account set*' }).Count | Should -Be 0
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
    $global:AuditOperatorFixture.DefaultSubscription | Should -Be '99999999-9999-9999-9999-999999999999'
  }

  It 'accepts explicit process selectors when selected environment output omits them' {
    [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $global:AuditOperatorFixture.AzdValues.AZURE_SUBSCRIPTION_ID, 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', $global:AuditOperatorFixture.AzdValues.AZURE_TENANT_ID, 'Process')
    $global:AuditOperatorFixture.AzdValues.Remove('AZURE_SUBSCRIPTION_ID')
    $global:AuditOperatorFixture.AzdValues.Remove('AZURE_TENANT_ID')
    (Assert-AuditOperatorTarget).UserPrincipalName | Should -Be 'operator@example.test'
  }

  It 'rejects missing or malformed selector <SelectorName> before Azure calls' -ForEach @(
    @{ SelectorName = 'AZURE_SUBSCRIPTION_ID'; Value = '' },
    @{ SelectorName = 'AZURE_TENANT_ID'; Value = '' },
    @{ SelectorName = 'AZURE_SUBSCRIPTION_ID'; Value = 'not-a-guid' },
    @{ SelectorName = 'AZURE_TENANT_ID'; Value = '00000000-0000-0000-0000-000000000000' }
  ) {
    $global:AuditOperatorFixture.AzdValues[$SelectorName] = $Value
    { Assert-AuditOperatorTarget } | Should -Throw '*Explicit nonempty*'
    $global:AuditOperatorFixture.Calls.Count | Should -Be 0
  }

  It 'rejects process and selected environment disagreement' {
    [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', '33333333-3333-3333-3333-333333333333', 'Process')
    { Assert-AuditOperatorTarget } | Should -Throw '*selectors disagree*'
    $global:AuditOperatorFixture.Calls.Count | Should -Be 0
  }

  It 'rejects an optional supplied subscription that disagrees with the selection' {
    { Assert-AuditOperatorTarget -SubscriptionId '33333333-3333-3333-3333-333333333333' } | Should -Throw '*does not match*'
    $global:AuditOperatorFixture.Calls.Count | Should -Be 0
  }

  It 'fails closed on <Kind> metadata' -ForEach @(
    @{ Kind = 'account subscription'; Section = 'Account'; Field = 'id'; Value = '33333333-3333-3333-3333-333333333333' },
    @{ Kind = 'account tenant'; Section = 'Account'; Field = 'tenantId'; Value = '33333333-3333-3333-3333-333333333333' },
    @{ Kind = 'account cloud'; Section = 'Account'; Field = 'environmentName'; Value = 'AzureUSGovernment' },
    @{ Kind = 'token subscription'; Section = 'Token'; Field = 'subscription'; Value = '33333333-3333-3333-3333-333333333333' },
    @{ Kind = 'token tenant'; Section = 'Token'; Field = 'tenant'; Value = '33333333-3333-3333-3333-333333333333' },
    @{ Kind = 'missing token'; Section = 'Token'; Field = 'accessToken'; Value = '' },
    @{ Kind = 'live ARM resource ID'; Section = 'Subscription'; Field = 'id'; Value = '/subscriptions/33333333-3333-3333-3333-333333333333' },
    @{ Kind = 'live ARM subscription'; Section = 'Subscription'; Field = 'subscriptionId'; Value = '33333333-3333-3333-3333-333333333333' },
    @{ Kind = 'live ARM tenant'; Section = 'Subscription'; Field = 'tenantId'; Value = '33333333-3333-3333-3333-333333333333' },
    @{ Kind = 'disabled subscription'; Section = 'Subscription'; Field = 'state'; Value = 'Disabled' },
    @{ Kind = 'noncanonical state'; Section = 'Subscription'; Field = 'state'; Value = 'enabled' },
    @{ Kind = 'missing state'; Section = 'Subscription'; Field = 'state'; Value = $null }
  ) {
    $global:AuditOperatorFixture[$Section][$Field] = $Value
    try { Assert-AuditOperatorTarget; throw 'Expected a guard failure.' }
    catch { $_.Exception.Data['AuditTargetGuard'] | Should -BeTrue }
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }

  It 'requires an identified user operator' -ForEach @('missing-name', 'service-principal') {
    if ($_ -eq 'missing-name') { $global:AuditOperatorFixture.Account.user.name = '' }
    else { $global:AuditOperatorFixture.Account.user.type = 'servicePrincipal' }
    { Assert-AuditOperatorTarget } | Should -Throw '*Unable to verify*'
  }

  It 'fails closed when the selected azd environment cannot be read' {
    $global:AuditOperatorFixture.AzdExit = 7
    { Assert-AuditOperatorTarget } | Should -Throw '*Could not inspect*'
    $global:AuditOperatorFixture.Calls.Count | Should -Be 0
  }

  It 'rejects nonzero account and token exits even with otherwise valid output' -ForEach @('AccountExit', 'TokenExit') {
    $global:AuditOperatorFixture[$_] = 7
    { Assert-AuditOperatorTarget } | Should -Throw '*Unable to verify*'
  }

  It 'sanitizes malformed token output and live provider failures' -ForEach @('BadTokenJson', 'LiveReadFailure') {
    $global:AuditOperatorFixture[$_] = $true
    try { Assert-AuditOperatorTarget; throw 'Expected a guard failure.' }
    catch {
      $_.Exception.Data['AuditTargetGuard'] | Should -BeTrue
      $_.ToString() | Should -Not -Match 'SECRET-SENTINEL'
    }
  }

  It 'does not permit returned-object mutation or sourcing Common again to reset the pin' {
    $target = Assert-AuditOperatorTarget
    $target.UserPrincipalName = 'changed@example.test'
    . "$script:repoRoot/hooks/Common.ps1"
    (Assert-AuditOperatorTarget).UserPrincipalName | Should -Be 'operator@example.test'
    $global:AuditOperatorFixture.Account.user.name = 'changed@example.test'
    { Assert-AuditOperatorTarget } | Should -Throw '*Unable to verify*'
  }

  It 'rejects selected tenant drift after a successful check' {
    Assert-AuditOperatorTarget | Out-Null
    $global:AuditOperatorFixture.AzdValues.AZURE_TENANT_ID = '33333333-3333-3333-3333-333333333333'
    { Assert-AuditOperatorTarget } | Should -Throw '*changed during this operation*'
  }
}

Describe 'Direct Common mutation helpers' {
  It 'guards environment persistence and emits no target object' {
    @(Set-AzdEnvironmentValue -Name 'AUTOMATION_ACCOUNT_NAME' -Value 'fixture-audit').Count | Should -Be 0
    $global:AuditOperatorFixture.LiveReads | Should -Be 1
    @($global:AuditOperatorFixture.Writes) | Should -Be @('env-set:AUTOMATION_ACCOUNT_NAME')
  }

  It 'refuses to persist any value while the subscription is disabled' {
    $global:AuditOperatorFixture.Subscription.state = 'Disabled'
    { Set-AzdEnvironmentValue -Name 'AUTOMATION_ACCOUNT_NAME' -Value 'fixture-audit' } | Should -Throw '*Unable to verify*'
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }

  It 'rechecks immediately before variable PUT without leaking a target object' {
    @(Set-AutomationVariableValue @script:commonArguments -VariableName 'fixture-variable' -Value 'fixture-value').Count | Should -Be 0
    $global:AuditOperatorFixture.LiveReads | Should -Be 2
    @($global:AuditOperatorFixture.Writes) | Should -Be @('variable-put')
  }

  It 'blocks variable PUT if the subscription changes after token acquisition' {
    $global:AuditOperatorFixture.DisableAtLiveRead = 2
    { Set-AutomationVariableValue @script:commonArguments -VariableName 'fixture-variable' -Value 'fixture-value' } | Should -Throw '*Unable to verify*'
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }

  It 'guards replace-content and publish independently' {
    @(Publish-AutomationRunbookContent @script:commonArguments -RunbookName 'fixture-runbook' -FilePath $script:runbookPath).Count | Should -Be 0
    $global:AuditOperatorFixture.LiveReads | Should -Be 2
    @($global:AuditOperatorFixture.Writes) | Should -Be @('replace-content', 'publish')
  }

  It 'blocks replace-content before the first write for a disabled target' {
    $global:AuditOperatorFixture.Subscription.state = 'Disabled'
    { Publish-AutomationRunbookContent @script:commonArguments -RunbookName 'fixture-runbook' -FilePath $script:runbookPath } | Should -Throw '*Unable to verify*'
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }

  It 'blocks publish if the target changes after replacing content' {
    $global:AuditOperatorFixture.DisableAfterReplace = $true
    { Publish-AutomationRunbookContent @script:commonArguments -RunbookName 'fixture-runbook' -FilePath $script:runbookPath } | Should -Throw '*Unable to verify*'
    @($global:AuditOperatorFixture.Writes) | Should -Be @('replace-content')
  }

  It 'guards runbook start and returns only the completed job' {
    $output = @(Start-AutomationRunbookAndWait @script:commonArguments -RunbookName 'fixture-runbook')
    $output.Count | Should -Be 1
    $output[0].status | Should -Be 'Completed'
    @($global:AuditOperatorFixture.Writes) | Should -Be @('start')
    $global:AuditOperatorFixture.LiveReads | Should -Be 1
  }

  It 'blocks runbook start for a disabled target' {
    $global:AuditOperatorFixture.Subscription.state = 'Disabled'
    { Start-AutomationRunbookAndWait @script:commonArguments -RunbookName 'fixture-runbook' } | Should -Throw '*Unable to verify*'
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }
}

Describe 'Actual postprovision token and Graph helpers with the real target guard' {
  It 'returns only the scoped token while the CLI default belongs to another subscription' {
    $tokens = @(Get-AzCliAccessToken -ResourceUrl 'https://graph.microsoft.com')
    $tokens.Count | Should -Be 1
    $tokens[0] | Should -Be 'TOKEN-SECRET-SENTINEL'
    $global:AuditOperatorFixture.LiveReads | Should -Be 1
    $global:AuditOperatorFixture.DefaultSubscription | Should -Be '99999999-9999-9999-9999-999999999999'
  }

  It 'rejects <Mode> returned Graph token metadata without allowing authentication fallback' -ForEach @(
    @{ Mode = 'wrong-tenant' }, @{ Mode = 'wrong-subscription' }, @{ Mode = 'malformed' }
  ) {
    $global:AuditOperatorFixture.ResourceTokenMode = $Mode
    try { Get-AzCliAccessToken -ResourceUrl 'https://graph.microsoft.com'; throw 'Expected guard failure.' }
    catch {
      $_.Exception.Data['AuditTargetGuard'] | Should -BeTrue
      $_.Exception.Data['AuditTokenUnavailable'] | Should -Not -BeTrue
      $_.ToString() | Should -Not -Match 'SECRET-SENTINEL'
    }
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }

  It 'distinguishes native token unavailability from invalid returned metadata' -ForEach @(
    @{ Mode = 'unavailable' }, @{ Mode = 'empty' }
  ) {
    $global:AuditOperatorFixture.ResourceTokenMode = $Mode
    try { Get-AzCliAccessToken -ResourceUrl 'https://graph.microsoft.com'; throw 'Expected token failure.' }
    catch {
      $_.Exception.Data['AuditTargetGuard'] | Should -BeTrue
      $_.Exception.Data['AuditTokenUnavailable'] | Should -BeTrue
    }
  }

  It 'never marks an ARM validation failure as optional token unavailability' {
    $global:AuditOperatorFixture.TokenExit = 7
    try { Get-AzCliAccessToken -ResourceUrl 'https://graph.microsoft.com'; throw 'Expected guard failure.' }
    catch {
      $_.Exception.Data['AuditTargetGuard'] | Should -BeTrue
      $_.Exception.Data['AuditTokenUnavailable'] | Should -Not -BeTrue
    }
  }

  It 'validates the actual Graph write immediately before dispatch' {
    $output = @(Invoke-GraphRest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals/fixture/appRoleAssignments' -Body '{}')
    $output.Count | Should -Be 1
    $output[0].id | Should -Be 'fixture-assignment'
    @($global:AuditOperatorFixture.Writes) | Should -Be @('graph-post')
    $global:AuditOperatorFixture.LiveReads | Should -Be 2
  }

  It 'blocks Graph writes on returned token metadata mismatch' {
    $global:AuditOperatorFixture.ResourceTokenMode = 'wrong-tenant'
    { Invoke-GraphRest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals/fixture/appRoleAssignments' -Body '{}' } | Should -Throw '*Could not acquire*'
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }

  It 'blocks Graph writes when the live subscription becomes disabled after token acquisition' {
    $global:AuditOperatorFixture.DisableAtLiveRead = 2
    { Invoke-GraphRest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals/fixture/appRoleAssignments' -Body '{}' } | Should -Throw '*Unable to verify*'
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }

  It 'blocks Graph writes when the operator changes after token acquisition' {
    $global:AuditOperatorFixture.DriftActorAfterResourceToken = $true
    { Invoke-GraphRest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals/fixture/appRoleAssignments' -Body '{}' } | Should -Throw '*Unable to verify*'
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }
}

Describe 'Actual preprovision and predown entrypoints' {
  It 'validates before every persisted preprovision value and preserves new-environment schedule ownership' {
    & "$script:repoRoot/hooks/preprovision.ps1"
    @($global:AuditOperatorFixture.Writes) | Should -Be @('env-set:AZURE_RESOURCE_GROUP', 'env-set:AUTOMATION_ACCOUNT_NAME', 'env-set:DEPLOYMENT_TIMESTAMP', 'env-set:AUTOMATION_JOB_SCHEDULE_ID')
    $global:AuditOperatorFixture.LiveReads | Should -Be 5
    $global:AuditOperatorFixture.AzdValues.AUTOMATION_JOB_SCHEDULE_ID | Should -Match '^[0-9a-f-]{36}$'
  }

  It 'stops preprovision before persistence for invalid target <Failure>' -ForEach @(@{ Failure = 'missing-tenant' }, @{ Failure = 'wrong-tenant' }, @{ Failure = 'disabled' }, @{ Failure = 'wrong-token' }) {
    switch ($Failure) {
      'missing-tenant' { $global:AuditOperatorFixture.AzdValues.Remove('AZURE_TENANT_ID') }
      'wrong-tenant' { $global:AuditOperatorFixture.Account.tenantId = '33333333-3333-3333-3333-333333333333' }
      'disabled' { $global:AuditOperatorFixture.Subscription.state = 'Disabled' }
      'wrong-token' { $global:AuditOperatorFixture.Token.tenant = '33333333-3333-3333-3333-333333333333' }
    }
    { & "$script:repoRoot/hooks/preprovision.ps1" } | Should -Throw
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }

  It 'stops later preprovision persistence after the subscription becomes disabled' {
    $global:AuditOperatorFixture.DisableAfterEnvironmentSet = $true
    { & "$script:repoRoot/hooks/preprovision.ps1" } | Should -Throw '*Unable to verify*'
    @($global:AuditOperatorFixture.Writes) | Should -Be @('env-set:AZURE_RESOURCE_GROUP')
  }

  It 'stops the full postprovision hook before writes for invalid target <Failure>' -ForEach @(
    @{ Failure = 'missing-tenant' }, @{ Failure = 'wrong-tenant' }, @{ Failure = 'disabled' }, @{ Failure = 'wrong-token' }
  ) {
    switch ($Failure) {
      'missing-tenant' { $global:AuditOperatorFixture.AzdValues.Remove('AZURE_TENANT_ID') }
      'wrong-tenant' { $global:AuditOperatorFixture.Account.tenantId = '33333333-3333-3333-3333-333333333333' }
      'disabled' { $global:AuditOperatorFixture.Subscription.state = 'Disabled' }
      'wrong-token' { $global:AuditOperatorFixture.Token.tenant = '33333333-3333-3333-3333-333333333333' }
    }
    try { & "$script:repoRoot/hooks/postprovision.ps1"; throw 'Expected guard failure.' }
    catch { $_.Exception.Data['AuditTargetGuard'] | Should -BeTrue }
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }

  It 'guards predown lock deletion with the explicit target' {
    & "$script:repoRoot/hooks/predown.ps1"
    @($global:AuditOperatorFixture.Writes) | Should -Be @('lock-delete')
    $global:AuditOperatorFixture.LiveReads | Should -Be 2
  }

  It 'validates predown even when no lock needs removal' {
    $global:AuditOperatorFixture.LockAbsent = $true
    $output = @(& "$script:repoRoot/hooks/predown.ps1")
    $output | Should -Be @('Automation account deletion lock was not present.')
    $global:AuditOperatorFixture.LiveReads | Should -Be 1
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }

  It 'blocks predown with a missing tenant before looking for the lock' {
    $global:AuditOperatorFixture.LockAbsent = $true
    $global:AuditOperatorFixture.AzdValues.Remove('AZURE_TENANT_ID')
    { & "$script:repoRoot/hooks/predown.ps1" } | Should -Throw '*Explicit nonempty*'
    $global:AuditOperatorFixture.Calls.Count | Should -Be 0
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }

  It 'blocks predown deletion when the target is disabled after the lock lookup' {
    $global:AuditOperatorFixture.DisableAfterLockRead = $true
    { & "$script:repoRoot/hooks/predown.ps1" } | Should -Throw '*Unable to verify*'
    $global:AuditOperatorFixture.Writes.Count | Should -Be 0
  }
}

AfterAll {
  foreach ($name in $script:selectorNames) { [Environment]::SetEnvironmentVariable($name, $script:previousEnvironment[$name], 'Process') }
  Remove-Variable -Name AuditOperatorTarget -Scope Script -ErrorAction SilentlyContinue
  Remove-Variable -Name AuditOperatorFixture -Scope Global -ErrorAction SilentlyContinue
}

}
