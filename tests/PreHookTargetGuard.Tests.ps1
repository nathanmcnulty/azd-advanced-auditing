#requires -Version 7.6

BeforeAll {
  $script:repoRoot = Split-Path $PSScriptRoot -Parent
  $script:preprovisionPath = Join-Path $script:repoRoot 'hooks/preprovision.ps1'
  $script:predownPath = Join-Path $script:repoRoot 'hooks/predown.ps1'
  $script:postprovisionPath = Join-Path $script:repoRoot 'hooks/postprovision.ps1'

  function global:az { throw 'Unmocked Azure CLI call is forbidden in this test.' }
  function global:azd { throw 'Unmocked azd call is forbidden in this test.' }
  function global:Invoke-WebRequest { throw 'Unmocked HTTP call is forbidden in this test.' }
}

Describe 'Auditing hook selected-target guard' {
  BeforeEach {
    $script:subscriptionId = '11111111-1111-1111-1111-111111111111'
    $script:tenantId = '22222222-2222-2222-2222-222222222222'
    $names = @(
      'AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_RESOURCE_GROUP', 'AUTOMATION_ACCOUNT_NAME',
      'AUTOMATION_JOB_SCHEDULE_ID', 'DEPLOYMENT_TIMESTAMP', 'AUTOMATION_OWNED_ACCOUNT_ID',
      'AUTOMATION_OWNED_PRINCIPAL_ID', 'AUTOMATION_OWNED_JOB_SCHEDULE_ID', 'AUTOMATION_ADOPT_ACCOUNT_ID',
      'AUTOMATION_ADOPT_PRINCIPAL_ID', 'AUTOMATION_ADOPT_JOB_SCHEDULE_ID', 'AUTOMATION_PRINCIPAL_ID',
      'VALIDATE_CONNECTION_RUNBOOK_NAME', 'VALIDATE_CONFIGURATION_RUNBOOK_NAME', 'EXCHANGE_ORGANIZATION', 'EXCHANGE_ORGANIZATION_VARIABLE_NAME',
      'OPERATIONAL_ALERTS_ENABLED'
    )
    $script:savedEnvironment = @{}
    foreach ($name in $names) { $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

    [Environment]::SetEnvironmentVariable('AZURE_ENV_NAME', 'offline', 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $script:subscriptionId, 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', $script:tenantId, 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_RESOURCE_GROUP', 'rg-offline', 'Process')
    [Environment]::SetEnvironmentVariable('AUTOMATION_ACCOUNT_NAME', 'aaauditoffline', 'Process')
    foreach ($name in $names | Where-Object { $_ -notin @('AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_RESOURCE_GROUP', 'AUTOMATION_ACCOUNT_NAME') }) {
      [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }

    $account = [pscustomobject]@{
      id = $script:subscriptionId
      tenantId = $script:tenantId
      user = [pscustomobject]@{ name = 'offline@example.invalid'; type = 'user' }
    }
    $token = [pscustomobject]@{
      accessToken = 'offline-token-sentinel'
      subscription = $script:subscriptionId
      tenant = $script:tenantId
    }
    $enabledSubscription = [pscustomobject]@{
      id = "/subscriptions/$($script:subscriptionId)"
      subscriptionId = $script:subscriptionId
      tenantId = $script:tenantId
      state = 'Enabled'
      # Optional ARM response fields such as displayName are intentionally absent.
    }

    $global:PreHookTargetFixture = [pscustomobject]@{
      SubscriptionId = $script:subscriptionId
      TenantId = $script:tenantId
      BoundEnvironment = 'offline'
      DefaultEnvironment = 'offline'
      DriftDefaultAfterGroupExists = $false
      DriftDefaultAfterLockShow = $false
      DriftResourceAfterLockShow = $false
      DriftResourceName = 'AUTOMATION_ACCOUNT_NAME'
      DriftProcessEnvironmentAfterLockShow = $false
      AzdValues = [ordered]@{
        AZURE_ENV_NAME = 'offline'
        AZURE_SUBSCRIPTION_ID = $script:subscriptionId
        AZURE_TENANT_ID = $script:tenantId
        AZURE_RESOURCE_GROUP = 'rg-offline'
        AUTOMATION_ACCOUNT_NAME = 'aaauditoffline'
      }
      OtherAzdValues = [ordered]@{
        AZURE_ENV_NAME = 'other'
        AZURE_SUBSCRIPTION_ID = '33333333-3333-3333-3333-333333333333'
        AZURE_TENANT_ID = '44444444-4444-4444-4444-444444444444'
        AZURE_RESOURCE_GROUP = 'rg-other'
        AUTOMATION_ACCOUNT_NAME = 'aaauditother'
      }
      AzdValuesByEnvironment = $null
      AmbientSubscription = '33333333-3333-3333-3333-333333333333'
      AmbientTenant = '44444444-4444-4444-4444-444444444444'
      AccountJson = $account | ConvertTo-Json -Compress
      AccountJsonOverride = ''
      AccountJsonOverrideAfterFirstArm = $false
      TokenJson = $token | ConvertTo-Json -Compress
      TokenJsonOverride = ''
      ArmResponses = [Collections.Generic.List[string]]::new()
      ArmResponseIndex = 0
      ArmStatusCode = 200
      LockExists = $true
      LockStatusCode = 200
      LockLevel = 'CanNotDelete'
      LockDeleteStatusCode = 204
      LockReturnedIdOverride = ''
      GroupExists = 'false'
      AzdExitCode = 0
      AzCalls = [Collections.Generic.List[object]]::new()
      AzdCalls = [Collections.Generic.List[object]]::new()
      WebCalls = [Collections.Generic.List[object]]::new()
      Writes = [Collections.Generic.List[string]]::new()
      DriftAfterFirstWrite = ''
      LockCalls = [Collections.Generic.List[object]]::new()
      DriftSelectorAfterLockShow = ''
      AccountReadCount = 0
      ReplaceAccountAfterRead = $false
      DriftAfterReplaceContent = $false
      Events = [Collections.Generic.List[string]]::new()
    }
    $global:PreHookTargetFixture.AzdValuesByEnvironment = @{
      offline = $global:PreHookTargetFixture.AzdValues
      other = $global:PreHookTargetFixture.OtherAzdValues
    }
    $enabledJson = $enabledSubscription | ConvertTo-Json -Compress
    $global:PreHookTargetFixture.ArmResponses.Add($enabledJson)

    Mock az {
      $fixture = $global:PreHookTargetFixture
      $argv = [string[]]$args
      $fixture.AzCalls.Add($argv)
      $command = $argv -join ' '
      $fixture.Events.Add("az:$command")
      $global:LASTEXITCODE = 0

      if ($argv.Count -ge 2 -and $argv[0] -eq 'account' -and $argv[1] -eq 'show') {
        $index = [Array]::IndexOf($argv, '--subscription')
        if ($index -ge 0 -and $index + 1 -lt $argv.Count -and $argv[$index + 1] -ieq $fixture.SubscriptionId) {
          if (-not [string]::IsNullOrEmpty($fixture.AccountJsonOverride) -and
              (-not $fixture.AccountJsonOverrideAfterFirstArm -or $fixture.LockCalls.Count -gt 0)) {
            return $fixture.AccountJsonOverride
          }
          return $fixture.AccountJson
        }
        return ('{{"id":"{0}","tenantId":"{1}","user":{{"name":"ambient@example.invalid"}}}}' -f $fixture.AmbientSubscription, $fixture.AmbientTenant)
      }

      if ($argv.Count -ge 2 -and $argv[0] -eq 'account' -and $argv[1] -eq 'get-access-token') {
        if (($argv -contains '--subscription') -and ($argv -contains '--tenant')) {
          throw 'The offline Azure CLI fixture rejects combined selectors.'
        }
        $index = [Array]::IndexOf($argv, '--subscription')
        if ($index -ge 0 -and $index + 1 -lt $argv.Count -and $argv[$index + 1] -ieq $fixture.SubscriptionId) {
          if (-not [string]::IsNullOrEmpty($fixture.TokenJsonOverride)) { return $fixture.TokenJsonOverride }
          return $fixture.TokenJson
        }
        return ('{{"accessToken":"ambient-token","subscription":"{0}","tenant":"{1}"}}' -f $fixture.AmbientSubscription, $fixture.AmbientTenant)
      }

      if ($argv.Count -ge 2 -and $argv[0] -eq 'group' -and $argv[1] -eq 'exists') {
        if ($fixture.DriftDefaultAfterGroupExists) { $fixture.DefaultEnvironment = 'other' }
        return $fixture.GroupExists
      }
      if ($command -like 'automation account show *') {
        $fixture.AccountReadCount++
        $group = $fixture.AzdValues['AZURE_RESOURCE_GROUP']
        $accountName = $fixture.AzdValues['AUTOMATION_ACCOUNT_NAME']
        $principalId = if ($fixture.ReplaceAccountAfterRead -and $fixture.AccountReadCount -gt 1) {
          '99999999-9999-9999-9999-999999999999'
        } else { $fixture.AzdValues['AUTOMATION_PRINCIPAL_ID'] }
        return (@{
          id = "/subscriptions/$($fixture.SubscriptionId)/resourceGroups/$group/providers/Microsoft.Automation/automationAccounts/$accountName"
          identity = @{principalId = $principalId}
        } | ConvertTo-Json -Compress)
      }
      if ($command -like 'rest --method GET *') {
        $uriIndex = [Array]::IndexOf($argv, '--uri')
        $id = ([uri]$argv[$uriIndex + 1]).AbsolutePath
        return (@{
          id = $id
          properties = @{
            jobScheduleId = $fixture.AzdValues['AUTOMATION_JOB_SCHEDULE_ID']
            schedule = @{name = 'advanced-auditing-daily'}
            runbook = @{name = 'Enable-AdvancedAuditing'}
          }
        } | ConvertTo-Json -Compress)
      }
      if ($command -like 'automation runbook show *') { return }
      if ($command -like 'automation runbook replace-content *') {
        $fixture.Writes.Add('replace-content')
        if ($fixture.DriftAfterReplaceContent) { $fixture.AzdValues['AUTOMATION_ACCOUNT_NAME'] = 'changed' }
        return
      }
      if ($command -like 'automation runbook publish *') { $fixture.Writes.Add('publish'); return }
      $global:LASTEXITCODE = 2
      throw "Unexpected mocked Azure command: $command"
    }

    Mock azd {
      $fixture = $global:PreHookTargetFixture
      $argv = [string[]]$args
      $environmentIndex = [Array]::IndexOf($argv, '--environment')
      $targetEnvironment = if ($environmentIndex -ge 0 -and $environmentIndex + 1 -lt $argv.Count) { $argv[$environmentIndex + 1] } else { $fixture.DefaultEnvironment }
      $fixture.AzdCalls.Add([pscustomobject]@{ Args = $argv; TargetEnvironment = $targetEnvironment })
      $command = $argv -join ' '
      $fixture.Events.Add("azd:$command [target=$targetEnvironment]")
      if ($argv.Count -ge 2 -and $argv[0] -eq 'env' -and $argv[1] -eq 'get-values') {
        $global:LASTEXITCODE = $fixture.AzdExitCode
        $values = $fixture.AzdValuesByEnvironment[$targetEnvironment]
        if ($null -eq $values) { $global:LASTEXITCODE = 2; throw "Unknown mocked azd environment: $targetEnvironment" }
        return @($values.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value })
      }
      if ($argv.Count -ge 2 -and $argv[0] -eq 'env' -and $argv[1] -eq 'set') {
        $global:LASTEXITCODE = 0
        $fixture.Writes.Add("azd-set:$targetEnvironment`:$($argv[2])")
        $fixture.AzdValuesByEnvironment[$targetEnvironment][$argv[2]] = $argv[3]
        if ($fixture.Writes.Count -eq 1) {
          switch ($fixture.DriftAfterFirstWrite) {
            'actor' {
              $account = $fixture.AccountJson | ConvertFrom-Json
              $account.user.name = 'other-operator@example.invalid'
              $fixture.AccountJsonOverride = $account | ConvertTo-Json -Compress
            }
            'tenant' { $fixture.AzdValues['AZURE_TENANT_ID'] = '44444444-4444-4444-4444-444444444444' }
            'subscription' { $fixture.AzdValues['AZURE_SUBSCRIPTION_ID'] = '33333333-3333-3333-3333-333333333333' }
            'target' { $fixture.AzdValues['AZURE_RESOURCE_GROUP'] = 'rg-replaced' }
          }
        }
        return
      }
      $global:LASTEXITCODE = 2
      throw "Unexpected mocked azd command: $command"
    }

    Mock Invoke-WebRequest {
      param([string]$Method, [string]$Uri, [hashtable]$Headers, [int]$MaximumRedirection, [int]$TimeoutSec)
      $fixture = $global:PreHookTargetFixture
      if ($Uri -like '*Microsoft.Authorization/locks/*') {
        $fixture.Events.Add("arm:lock-$Method")
        $fixture.LockCalls.Add(@{Method = $Method; Uri = $Uri; Authorization = $Headers.Authorization})
        if ($Method -eq 'DELETE') {
          $fixture.Writes.Add('lock-delete')
          return [pscustomobject]@{ StatusCode = $fixture.LockDeleteStatusCode; Content = '{}' }
        }
        if ($fixture.DriftDefaultAfterLockShow) { $fixture.DefaultEnvironment = 'other' }
        if ($fixture.DriftResourceAfterLockShow) {
          $changedValue = if ($fixture.DriftResourceName -eq 'AZURE_RESOURCE_GROUP') { 'rg-auditchanged' } else { 'aaauditchanged' }
          $fixture.AzdValuesByEnvironment[$fixture.BoundEnvironment][$fixture.DriftResourceName] = $changedValue
          [Environment]::SetEnvironmentVariable($fixture.DriftResourceName, $changedValue, 'Process')
        }
        if ($fixture.DriftProcessEnvironmentAfterLockShow) {
          [Environment]::SetEnvironmentVariable('AZURE_ENV_NAME', 'other', 'Process')
        }
        if ($fixture.DriftSelectorAfterLockShow) {
          $fixture.AzdValues[$fixture.DriftSelectorAfterLockShow] = '33333333-3333-3333-3333-333333333333'
        }
        if ($fixture.LockStatusCode -ne 200) { return [pscustomobject]@{ StatusCode = $fixture.LockStatusCode; Content = '{"error":{"code":"AuthorizationFailed"}}' } }
        if (-not $fixture.LockExists) { return [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"LockNotFound"}}' } }
        $returnedId = if ($fixture.LockReturnedIdOverride) { $fixture.LockReturnedIdOverride } else { ([uri]$Uri).AbsolutePath }
        return [pscustomobject]@{
          StatusCode = 200
          Content = (@{ id = $returnedId; properties = @{ level = $fixture.LockLevel } } | ConvertTo-Json -Compress)
        }
      }
      $fixture.WebCalls.Add([pscustomobject]@{
          Method = $Method
          Uri = $Uri
          HasBearer = [string]$Headers.Authorization -like 'Bearer *'
          MaximumRedirection = $MaximumRedirection
          TimeoutSec = $TimeoutSec
        })
      $fixture.Events.Add('arm:get-subscription')
      $index = [Math]::Min($fixture.ArmResponseIndex, $fixture.ArmResponses.Count - 1)
      $content = $fixture.ArmResponses[$index]
      $fixture.ArmResponseIndex++
      return [pscustomobject]@{ StatusCode = $fixture.ArmStatusCode; Content = $content }
    }
  }

  AfterEach {
    foreach ($name in $script:savedEnvironment.Keys) {
      [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name], 'Process')
    }
    Remove-Variable PreHookTargetFixture -Scope Global -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = 0
  }

  It 'uses explicit subscription and verifies fresh Enabled state before preprovision writes or resource reads' {
    & $script:preprovisionPath

    $tokenCall = @($global:PreHookTargetFixture.AzCalls | Where-Object { $_[0] -eq 'account' -and $_[1] -eq 'get-access-token' })[0]
    $tokenCall | Should -Contain '--subscription'
    $tokenCall | Should -Contain $script:subscriptionId
    $tokenCall | Should -Not -Contain '--tenant'
    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 5
    $global:PreHookTargetFixture.WebCalls[0].Uri | Should -BeExactly "https://management.azure.com/subscriptions/$($script:subscriptionId)?api-version=2022-12-01"
    $global:PreHookTargetFixture.WebCalls[0].HasBearer | Should -BeTrue
    $global:PreHookTargetFixture.WebCalls[0].MaximumRedirection | Should -Be 0
    $firstWrite = @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'azd:env set*' })[0]
    $firstWriteIndex = $global:PreHookTargetFixture.Events.IndexOf($firstWrite)
    $armIndex = $global:PreHookTargetFixture.Events.IndexOf('arm:get-subscription')
    $armIndex | Should -BeLessThan $firstWriteIndex
    $groupReadIndex = @($global:PreHookTargetFixture.Events | ForEach-Object { $_ } | Where-Object { $_ -like 'az:group exists --subscription *' })
    $global:PreHookTargetFixture.Events.IndexOf('arm:get-subscription') | Should -BeLessThan $global:PreHookTargetFixture.Events.IndexOf($groupReadIndex[0])
    $finalArmIndex = $global:PreHookTargetFixture.Events.LastIndexOf('arm:get-subscription')
    $finalWrite = @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'azd:env set AUTOMATION_JOB_SCHEDULE_ID *' })[0]
    $finalWriteIndex = $global:PreHookTargetFixture.Events.IndexOf($finalWrite)
    $finalArmIndex | Should -BeLessThan $finalWriteIndex
    $global:PreHookTargetFixture.Writes | Should -Contain 'azd-set:offline:AUTOMATION_JOB_SCHEDULE_ID'
    foreach ($call in $global:PreHookTargetFixture.AzdCalls) {
      $call.Args | Should -Contain '--environment'
      $call.TargetEnvironment | Should -BeExactly 'offline'
    }
  }

  It 'keeps every preprovision write pinned when the azd default environment changes during discovery' {
    $global:PreHookTargetFixture.DriftDefaultAfterGroupExists = $true

    & $script:preprovisionPath

    $global:PreHookTargetFixture.DefaultEnvironment | Should -BeExactly 'other'
    $global:PreHookTargetFixture.Writes | Should -Contain 'azd-set:offline:AUTOMATION_JOB_SCHEDULE_ID'
    @($global:PreHookTargetFixture.Writes | Where-Object { $_ -like 'azd-set:other:*' }).Count | Should -Be 0
    foreach ($call in $global:PreHookTargetFixture.AzdCalls) {
      $call.Args | Should -Contain '--environment'
      $call.TargetEnvironment | Should -BeExactly 'offline'
    }
  }

  It 'leaves earlier environment outputs intact but refuses final schedule persistence if Enabled state changes after discovery' {
    $disabledState = $global:PreHookTargetFixture.ArmResponses[0] | ConvertFrom-Json
    $disabledState.state = 'Disabled'
    $disabledJson = $disabledState | ConvertTo-Json -Compress
    foreach ($index in 1..3) {
      $global:PreHookTargetFixture.ArmResponses.Add($global:PreHookTargetFixture.ArmResponses[0])
    }
    $global:PreHookTargetFixture.ArmResponses.Add($disabledJson)

    { & $script:preprovisionPath } | Should -Throw '*not Enabled*'

    $global:PreHookTargetFixture.Writes | Should -Contain 'azd-set:offline:AZURE_RESOURCE_GROUP'
    $global:PreHookTargetFixture.Writes | Should -Contain 'azd-set:offline:AUTOMATION_ACCOUNT_NAME'
    @($global:PreHookTargetFixture.Writes | Where-Object { $_ -like '*AUTOMATION_JOB_SCHEDULE_ID' }).Count | Should -Be 0
    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 5
  }

  It 'refuses the next environment write when the <Drift> changes after the first write' -ForEach @(
    @{Drift = 'actor'}, @{Drift = 'tenant'}, @{Drift = 'subscription'}, @{Drift = 'target'}
  ) {
    $global:PreHookTargetFixture.DriftAfterFirstWrite = $Drift
    { & $script:preprovisionPath } | Should -Throw
    $global:PreHookTargetFixture.Writes | Should -Be @('azd-set:offline:AZURE_RESOURCE_GROUP')
  }

  It 'allows an authoritative lock absence but stops teardown if a lock read is denied' {
    $global:PreHookTargetFixture.LockExists = $false
    { & $script:predownPath } | Should -Not -Throw
    $global:PreHookTargetFixture.LockStatusCode = 403
    { & $script:predownPath } | Should -Throw '*could not be verified*'
    $global:PreHookTargetFixture.Writes.Count | Should -Be 0
  }

  It 'does not remove changed lock protection or replay an unconfirmed deletion' {
    $global:PreHookTargetFixture.LockLevel = 'ReadOnly'
    { & $script:predownPath } | Should -Throw '*expected CanNotDelete*'
    $global:PreHookTargetFixture.Writes.Count | Should -Be 0
    $global:PreHookTargetFixture.LockLevel = 'CanNotDelete'
    $global:PreHookTargetFixture.LockDeleteStatusCode = 202
    { & $script:predownPath } | Should -Throw '*could not be confirmed*'
    $global:PreHookTargetFixture.Writes | Should -Be @('lock-delete')
  }

  It 'refuses lock deletion when the <Selector> changes after lock lookup' -ForEach @(
    @{Selector = 'AZURE_TENANT_ID'}, @{Selector = 'AZURE_SUBSCRIPTION_ID'}
  ) {
    $global:PreHookTargetFixture.DriftSelectorAfterLockShow = $Selector
    { & $script:predownPath } | Should -Throw '*do not match*'
    $global:PreHookTargetFixture.LockCalls.Method | Should -Be @('GET')
    $global:PreHookTargetFixture.Writes.Count | Should -Be 0
  }

  It 'stops before another receipt when the operator changes after the first postprovision write' {
    $global:PreHookTargetFixture.AzdValues['AUTOMATION_PRINCIPAL_ID'] = '88888888-8888-8888-8888-888888888888'
    $global:PreHookTargetFixture.AzdValues['AUTOMATION_JOB_SCHEDULE_ID'] = '99999999-9999-9999-9999-999999999999'
    $global:PreHookTargetFixture.DriftAfterFirstWrite = 'actor'
    Mock Install-Module { throw 'Module installation is forbidden in offline tests.' }
    Mock Import-Module { throw 'Postprovision must stop before loading Exchange.' } -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
    { & $script:postprovisionPath } | Should -Throw '*CLI operator changed before a write*'
    $global:PreHookTargetFixture.Writes | Should -Be @('azd-set:offline:AUTOMATION_OWNED_ACCOUNT_ID')
  }

  It 'refuses postprovision receipt writes if the account principal changed after initial ownership verification' {
    $global:PreHookTargetFixture.AzdValues['AUTOMATION_PRINCIPAL_ID'] = '88888888-8888-8888-8888-888888888888'
    $global:PreHookTargetFixture.AzdValues['AUTOMATION_JOB_SCHEDULE_ID'] = '99999999-9999-9999-9999-999999999999'
    $global:PreHookTargetFixture.ReplaceAccountAfterRead = $true
    Mock Install-Module { throw 'Module installation is forbidden in offline tests.' }
    Mock Import-Module { throw 'Postprovision must stop before loading Exchange.' } -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
    { & $script:postprovisionPath } | Should -Throw '*managed identity could not be reverified*'
    $global:PreHookTargetFixture.Writes.Count | Should -Be 0
  }

  It 'rechecks the pinned resource after replacing runbook content and before publishing' {
    $global:PreHookTargetFixture.DriftAfterReplaceContent = $true
    . (Join-Path $script:repoRoot 'hooks/Common.ps1')
    $azdValues = Get-AuditPinnedAzdEnvironmentValues -EnvironmentName 'offline'
    $context = New-AuditHookContext -EnvironmentName 'offline' -AzdValues $azdValues -TargetNames @()
    $runbook = Join-Path $script:repoRoot 'runbooks/Enable-AdvancedAuditing.ps1'
    { Publish-AutomationRunbookContent -SubscriptionId $script:subscriptionId -ResourceGroupName 'rg-offline' -AutomationAccountName 'aaauditoffline' `
        -RunbookName 'Enable-AdvancedAuditing' -FilePath $runbook -HookContext $context } | Should -Throw '*do not match*'
    $global:PreHookTargetFixture.Writes | Should -Be @('replace-content')
  }

  It 'stops both pre-hook entrypoints before downstream dispatch when selected process and azd selectors drift' -ForEach @(
    @{ Hook = 'preprovision'; Selector = 'AZURE_SUBSCRIPTION_ID'; Value = '33333333-3333-3333-3333-333333333333' },
    @{ Hook = 'predown'; Selector = 'AZURE_SUBSCRIPTION_ID'; Value = '33333333-3333-3333-3333-333333333333' },
    @{ Hook = 'preprovision'; Selector = 'AZURE_TENANT_ID'; Value = '44444444-4444-4444-4444-444444444444' },
    @{ Hook = 'predown'; Selector = 'AZURE_TENANT_ID'; Value = '44444444-4444-4444-4444-444444444444' }
  ) {
    $global:PreHookTargetFixture.AzdValues[$Selector] = $Value
    $hookPath = if ($Hook -eq 'preprovision') { $script:preprovisionPath } else { $script:predownPath }

    { & $hookPath } | Should -Throw '*do not match*'
    @($global:PreHookTargetFixture.AzCalls).Count | Should -Be 0
    @($global:PreHookTargetFixture.Writes).Count | Should -Be 0
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:group exists*' -or $_ -like 'arm:lock-GET*' -or $_ -like 'arm:lock-DELETE*' }).Count | Should -Be 0
  }

  It 'stops both pre-hook entrypoints before CLI or mutation when selected azd values cannot be read' -ForEach @(
    @{ Hook = 'preprovision' }, @{ Hook = 'predown' }
  ) {
    $global:PreHookTargetFixture.AzdExitCode = 1
    $hookPath = if ($Hook -eq 'preprovision') { $script:preprovisionPath } else { $script:predownPath }

    { & $hookPath } | Should -Throw '*Could not read the selected azd environment values*'
    @($global:PreHookTargetFixture.AzCalls).Count | Should -Be 0
    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 0
    @($global:PreHookTargetFixture.Writes).Count | Should -Be 0
  }

  It 'stops before environment persistence when account JSON is a singleton array' {
    $validAccount = $global:PreHookTargetFixture.AccountJson | ConvertFrom-Json
    $global:PreHookTargetFixture.AccountJsonOverride = ConvertTo-Json -InputObject @($validAccount) -Compress

    { & $script:preprovisionPath } | Should -Throw '*malformed selected-account metadata*'
    @($global:PreHookTargetFixture.Writes).Count | Should -Be 0
    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 0
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:group exists*' }).Count | Should -Be 0
  }

  It 'stops before HTTP or persistence when token JSON is a singleton array' {
    $validToken = $global:PreHookTargetFixture.TokenJson | ConvertFrom-Json
    $global:PreHookTargetFixture.TokenJsonOverride = ConvertTo-Json -InputObject @($validToken) -Compress

    { & $script:preprovisionPath } | Should -Throw '*malformed token metadata*'
    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 0
    @($global:PreHookTargetFixture.Writes).Count | Should -Be 0
  }

  It 'rejects malformed singleton-array ARM state before preprovision persistence or predown lock lookup' -ForEach @(
    @{ Hook = 'preprovision' }, @{ Hook = 'predown' }
  ) {
    $validState = $global:PreHookTargetFixture.ArmResponses[0] | ConvertFrom-Json
    $global:PreHookTargetFixture.ArmResponses.Clear()
    $global:PreHookTargetFixture.ArmResponses.Add((ConvertTo-Json -InputObject @($validState) -Compress))
    $hookPath = if ($Hook -eq 'preprovision') { $script:preprovisionPath } else { $script:predownPath }

    { & $hookPath } | Should -Throw '*malformed selected-subscription metadata*'
    @($global:PreHookTargetFixture.Writes).Count | Should -Be 0
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:group exists*' -or $_ -like 'arm:lock-GET*' -or $_ -like 'arm:lock-DELETE*' }).Count | Should -Be 0
  }

  It 'rejects Disabled or mismatched fresh ARM state before any pre-hook persistence or lock handling' -ForEach @(
    @{ Hook = 'preprovision'; Mode = 'disabled' }, @{ Hook = 'predown'; Mode = 'wrong-tenant' }
  ) {
    $state = $global:PreHookTargetFixture.ArmResponses[0] | ConvertFrom-Json
    if ($Mode -eq 'disabled') { $state.state = 'Disabled' }
    else { $state.tenantId = $global:PreHookTargetFixture.AmbientTenant }
    $global:PreHookTargetFixture.ArmResponses.Clear()
    $global:PreHookTargetFixture.ArmResponses.Add(($state | ConvertTo-Json -Compress))
    $hookPath = if ($Hook -eq 'preprovision') { $script:preprovisionPath } else { $script:predownPath }

    { & $hookPath } | Should -Throw
    @($global:PreHookTargetFixture.Writes).Count | Should -Be 0
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:group exists*' -or $_ -like 'arm:lock-GET*' -or $_ -like 'arm:lock-DELETE*' }).Count | Should -Be 0
  }

  It 'rechecks current Enabled state immediately before predown lock deletion' {
    $validState = $global:PreHookTargetFixture.ArmResponses[0]
    $disabledState = ($validState | ConvertFrom-Json)
    $disabledState.state = 'Disabled'
    $global:PreHookTargetFixture.ArmResponses.Clear()
    $global:PreHookTargetFixture.ArmResponses.Add($validState)
    $global:PreHookTargetFixture.ArmResponses.Add(($disabledState | ConvertTo-Json -Compress))

    { & $script:predownPath } | Should -Throw '*not Enabled*'
    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 2
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'arm:lock-DELETE*' }).Count | Should -Be 0
    @($global:PreHookTargetFixture.Writes).Count | Should -Be 0
  }

  It 'does not delete a lock reported for a different exact resource' {
    $global:PreHookTargetFixture.LockReturnedIdOverride = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-other/providers/Microsoft.Authorization/locks/other'

    { & $script:predownPath } | Should -Throw '*different Automation lock*'

    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'arm:lock-DELETE*' }).Count | Should -Be 0
    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 1
  }

  It 'refuses predown when the process environment changes during lock lookup' {
    $global:PreHookTargetFixture.DriftProcessEnvironmentAfterLockShow = $true

    { & $script:predownPath } | Should -Throw '*process azd environment changed*'

    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'arm:lock-DELETE*' }).Count | Should -Be 0
  }

  It 'reads the pinned predown environment even if the azd default selection changes' {
    $global:PreHookTargetFixture.DriftDefaultAfterLockShow = $true

    & $script:predownPath

    $global:PreHookTargetFixture.DefaultEnvironment | Should -BeExactly 'other'
    @($global:PreHookTargetFixture.AzdCalls | Where-Object { $_.TargetEnvironment -ne 'offline' }).Count | Should -Be 0
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'arm:lock-DELETE*' }).Count | Should -Be 1
  }

  It 'refuses predown when the resource group or Automation account changes during lock lookup' -ForEach @(
    @{ ResourceName = 'AZURE_RESOURCE_GROUP' }, @{ ResourceName = 'AUTOMATION_ACCOUNT_NAME' }
  ) {
    $global:PreHookTargetFixture.DriftResourceAfterLockShow = $true
    $global:PreHookTargetFixture.DriftResourceName = $ResourceName

    { & $script:predownPath } | Should -Throw '*changed before a write*'

    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'arm:lock-DELETE*' }).Count | Should -Be 0
  }

  It 'refuses predown when the CLI actor changes during lock lookup' {
    $changedAccount = [pscustomobject]@{
      id = $script:subscriptionId
      tenantId = $script:tenantId
      user = [pscustomobject]@{ name = 'changed@example.invalid'; type = 'user' }
    }
    $global:PreHookTargetFixture.AccountJsonOverride = $changedAccount | ConvertTo-Json -Compress
    $global:PreHookTargetFixture.AccountJsonOverrideAfterFirstArm = $true

    { & $script:predownPath } | Should -Throw '*CLI operator changed before a write*'

    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 2
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'arm:lock-DELETE*' }).Count | Should -Be 0
  }

  It 'preserves the ordinary explicit-target predown lock path' {
    & $script:predownPath

    $lockCalls = $global:PreHookTargetFixture.LockCalls
    $secondArmIndex = $global:PreHookTargetFixture.Events.LastIndexOf('arm:get-subscription')
    $deleteIndex = $global:PreHookTargetFixture.Events.IndexOf('arm:lock-DELETE')
    $lockCalls.Method | Should -Be @('GET', 'DELETE')
    $lockCalls[0].Uri | Should -Match ([regex]::Escape("/subscriptions/$($script:subscriptionId)/"))
    $lockCalls[1].Uri | Should -BeExactly $lockCalls[0].Uri
    $lockCalls[1].Authorization | Should -BeExactly $lockCalls[0].Authorization
    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 2
    $secondArmIndex | Should -BeLessThan $deleteIndex
    $global:PreHookTargetFixture.Writes | Should -Contain 'lock-delete'
    foreach ($call in $global:PreHookTargetFixture.AzdCalls) {
      $call.Args | Should -Contain '--environment'
      $call.TargetEnvironment | Should -BeExactly 'offline'
    }
  }
}

AfterAll {
  foreach ($name in @('az', 'azd', 'Invoke-WebRequest')) {
    Remove-Item ('Function:global:' + $name) -ErrorAction SilentlyContinue
  }
  Remove-Variable PreHookTargetFixture -Scope Global -ErrorAction SilentlyContinue
}
