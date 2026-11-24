#requires -Version 7.6

BeforeAll {
  $script:repoRoot = Split-Path $PSScriptRoot -Parent
  $script:preprovisionPath = Join-Path $script:repoRoot 'hooks/preprovision.ps1'
  $script:predownPath = Join-Path $script:repoRoot 'hooks/predown.ps1'

  function global:az { throw 'Unmocked Azure CLI call is forbidden in this test.' }
  function global:azd { throw 'Unmocked azd call is forbidden in this test.' }
  function global:Invoke-WebRequest { throw 'Unmocked HTTP call is forbidden in this test.' }
}

Describe 'Preprovision and predown selected-target guard' {
  BeforeEach {
    $script:subscriptionId = '11111111-1111-1111-1111-111111111111'
    $script:tenantId = '22222222-2222-2222-2222-222222222222'
    $names = @(
      'AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_RESOURCE_GROUP', 'AUTOMATION_ACCOUNT_NAME',
      'AUTOMATION_JOB_SCHEDULE_ID', 'DEPLOYMENT_TIMESTAMP', 'AUTOMATION_OWNED_ACCOUNT_ID',
      'AUTOMATION_OWNED_PRINCIPAL_ID', 'AUTOMATION_OWNED_JOB_SCHEDULE_ID', 'AUTOMATION_ADOPT_ACCOUNT_ID',
      'AUTOMATION_ADOPT_PRINCIPAL_ID', 'AUTOMATION_ADOPT_JOB_SCHEDULE_ID'
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
      LockReturnedIdOverride = ''
      GroupExists = 'false'
      AzdExitCode = 0
      AzCalls = [Collections.Generic.List[object]]::new()
      AzdCalls = [Collections.Generic.List[object]]::new()
      WebCalls = [Collections.Generic.List[object]]::new()
      Writes = [Collections.Generic.List[string]]::new()
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
              (-not $fixture.AccountJsonOverrideAfterFirstArm -or $fixture.WebCalls.Count -gt 0)) {
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
      if ($argv.Count -ge 2 -and $argv[0] -eq 'lock' -and $argv[1] -eq 'show') {
        if ($fixture.DriftDefaultAfterLockShow) { $fixture.DefaultEnvironment = 'other' }
        if ($fixture.DriftResourceAfterLockShow) {
          $changedValue = if ($fixture.DriftResourceName -eq 'AZURE_RESOURCE_GROUP') { 'rg-auditchanged' } else { 'aaauditchanged' }
          $fixture.AzdValuesByEnvironment[$fixture.BoundEnvironment][$fixture.DriftResourceName] = $changedValue
          [Environment]::SetEnvironmentVariable($fixture.DriftResourceName, $changedValue, 'Process')
        }
        if ($fixture.DriftProcessEnvironmentAfterLockShow) {
          [Environment]::SetEnvironmentVariable('AZURE_ENV_NAME', 'other', 'Process')
        }
        if ($fixture.LockExists) {
          $idsIndex = [Array]::IndexOf($argv, '--ids')
          $returnedId = if (-not [string]::IsNullOrEmpty($fixture.LockReturnedIdOverride)) { $fixture.LockReturnedIdOverride } else { $argv[$idsIndex + 1] }
          return ([pscustomobject]@{ id = $returnedId } | ConvertTo-Json -Compress)
        }
        return ''
      }
      if ($argv.Count -ge 2 -and $argv[0] -eq 'lock' -and $argv[1] -eq 'delete') {
        $fixture.Writes.Add('lock-delete')
        return
      }

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
        return
      }
      $global:LASTEXITCODE = 2
      throw "Unexpected mocked azd command: $command"
    }

    Mock Invoke-WebRequest {
      param([string]$Method, [string]$Uri, [hashtable]$Headers, [int]$MaximumRedirection, [int]$TimeoutSec)
      $fixture = $global:PreHookTargetFixture
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
    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 2
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
    $global:PreHookTargetFixture.ArmResponses.Add($disabledJson)

    { & $script:preprovisionPath } | Should -Throw '*not Enabled*'

    $global:PreHookTargetFixture.Writes | Should -Contain 'azd-set:offline:AZURE_RESOURCE_GROUP'
    $global:PreHookTargetFixture.Writes | Should -Contain 'azd-set:offline:AUTOMATION_ACCOUNT_NAME'
    @($global:PreHookTargetFixture.Writes | Where-Object { $_ -like '*AUTOMATION_JOB_SCHEDULE_ID' }).Count | Should -Be 0
    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 2
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
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:group exists*' -or $_ -like 'az:lock show*' -or $_ -like 'az:lock delete*' }).Count | Should -Be 0
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
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:group exists*' -or $_ -like 'az:lock show*' -or $_ -like 'az:lock delete*' }).Count | Should -Be 0
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
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:group exists*' -or $_ -like 'az:lock show*' -or $_ -like 'az:lock delete*' }).Count | Should -Be 0
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
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:lock delete*' }).Count | Should -Be 0
    @($global:PreHookTargetFixture.Writes).Count | Should -Be 0
  }

  It 'does not delete a lock reported for a different exact resource' {
    $global:PreHookTargetFixture.LockReturnedIdOverride = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-other/providers/Microsoft.Authorization/locks/other'

    { & $script:predownPath } | Should -Throw '*different Automation lock*'

    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:lock delete*' }).Count | Should -Be 0
    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 1
  }

  It 'refuses predown when the process environment changes during lock lookup' {
    $global:PreHookTargetFixture.DriftProcessEnvironmentAfterLockShow = $true

    { & $script:predownPath } | Should -Throw '*process azd environment changed*'

    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:lock delete*' }).Count | Should -Be 0
  }

  It 'reads the pinned predown environment even if the azd default selection changes' {
    $global:PreHookTargetFixture.DriftDefaultAfterLockShow = $true

    & $script:predownPath

    $global:PreHookTargetFixture.DefaultEnvironment | Should -BeExactly 'other'
    @($global:PreHookTargetFixture.AzdCalls | Where-Object { $_.TargetEnvironment -ne 'offline' }).Count | Should -Be 0
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:lock delete*' }).Count | Should -Be 1
  }

  It 'refuses predown when the resource group or Automation account changes during lock lookup' -ForEach @(
    @{ ResourceName = 'AZURE_RESOURCE_GROUP' }, @{ ResourceName = 'AUTOMATION_ACCOUNT_NAME' }
  ) {
    $global:PreHookTargetFixture.DriftResourceAfterLockShow = $true
    $global:PreHookTargetFixture.DriftResourceName = $ResourceName

    { & $script:predownPath } | Should -Throw '*changed before the lock could be removed*'

    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:lock delete*' }).Count | Should -Be 0
  }

  It 'refuses predown when the CLI actor changes during lock lookup' {
    $changedAccount = [pscustomobject]@{
      id = $script:subscriptionId
      tenantId = $script:tenantId
      user = [pscustomobject]@{ name = 'changed@example.invalid'; type = 'user' }
    }
    $global:PreHookTargetFixture.AccountJsonOverride = $changedAccount | ConvertTo-Json -Compress
    $global:PreHookTargetFixture.AccountJsonOverrideAfterFirstArm = $true

    { & $script:predownPath } | Should -Throw '*CLI operator*changed before the lock could be removed*'

    $global:PreHookTargetFixture.WebCalls.Count | Should -Be 2
    @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:lock delete*' }).Count | Should -Be 0
  }

  It 'preserves the ordinary explicit-target predown lock path' {
    & $script:predownPath

    $lockShow = @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:lock show*' })[0]
    $lockDelete = @($global:PreHookTargetFixture.Events | Where-Object { $_ -like 'az:lock delete*' })[0]
    $secondArmIndex = $global:PreHookTargetFixture.Events.LastIndexOf('arm:get-subscription')
    $deleteIndex = $global:PreHookTargetFixture.Events.IndexOf($lockDelete)
    $lockShow | Should -Match ([regex]::Escape("--subscription $($script:subscriptionId)"))
    $lockDelete | Should -Match ([regex]::Escape("--subscription $($script:subscriptionId)"))
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
