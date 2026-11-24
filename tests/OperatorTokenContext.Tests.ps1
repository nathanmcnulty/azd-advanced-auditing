#requires -Version 7.6

BeforeAll {
  $script:repoRoot = Split-Path $PSScriptRoot -Parent
  . "$script:repoRoot/hooks/Common.ps1"

  $tokens = $null
  $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile("$script:repoRoot/hooks/postprovision.ps1", [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors) { throw ($parseErrors | Out-String) }
  $functionNames = @('Get-AzCliAccessToken', 'Get-AzCliUserPrincipalName', 'Connect-ExchangeForBootstrap', 'Invoke-GraphRest', 'Get-ExchangeOrganizationDomain')
  $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $functionNames -contains $node.Name }, $true))
  if ($definitions.Count -ne $functionNames.Count) { throw 'Expected the maintained operator token and fallback functions.' }
  $script:postprovisionDefinitions = [scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`n")

  function az {
    $global:OperatorTokenFixture.Calls.Add([pscustomobject]@{ Args = @($args) })
    $isAccount = $args[0] -eq 'account' -and $args[1] -eq 'show'
    $isToken = $args[0] -eq 'account' -and $args[1] -eq 'get-access-token'
    $hasSubscription = $args -contains '--subscription'
    $hasTenant = $args -contains '--tenant'
    if ($isToken -and $hasSubscription -and $hasTenant) {
      $global:LASTEXITCODE = 2
      throw 'The offline Azure CLI fixture rejects combined subscription and tenant selectors.'
    }

    $global:LASTEXITCODE = 0
    if ($isAccount -and $global:OperatorTokenFixture.AccountStderr) {
      Write-Error 'SYNTHETIC_ACCOUNT_STDERR_SECRET' -ErrorAction Continue
    }
    if ($isToken -and $global:OperatorTokenFixture.TokenStderr) {
      Write-Error 'SYNTHETIC_TOKEN_STDERR_SECRET' -ErrorAction Continue
    }
    if ($args[0] -eq 'account' -and $args[1] -eq 'show') {
      $accountSubscription = if ($hasSubscription) { $global:OperatorTokenFixture.AccountSubscription } else { $global:OperatorTokenFixture.AmbientSubscription }
      $accountTenant = if ($hasSubscription) { $global:OperatorTokenFixture.AccountTenant } else { $global:OperatorTokenFixture.AmbientTenant }
      if ($global:OperatorTokenFixture.AccountExitCode -ne 0) {
        $global:LASTEXITCODE = $global:OperatorTokenFixture.AccountExitCode
      }
      if (-not [string]::IsNullOrEmpty($global:OperatorTokenFixture.AccountJsonOverride)) {
        return $global:OperatorTokenFixture.AccountJsonOverride
      }
      return ([pscustomobject]@{
        id = $accountSubscription
        tenantId = $accountTenant
        user = [pscustomobject]@{ name = 'operator@example.test' }
      } | ConvertTo-Json -Compress)
    }
    if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') {
      $tokenSubscription = if ($hasSubscription) { $global:OperatorTokenFixture.TokenSubscription } else { $global:OperatorTokenFixture.AmbientSubscription }
      $tokenTenant = if ($hasSubscription) { $global:OperatorTokenFixture.TokenTenant } else { $global:OperatorTokenFixture.AmbientTenant }
      if ($global:OperatorTokenFixture.TokenExitCode -ne 0) {
        $global:LASTEXITCODE = $global:OperatorTokenFixture.TokenExitCode
      }
      if (-not [string]::IsNullOrEmpty($global:OperatorTokenFixture.TokenJsonOverride)) {
        return $global:OperatorTokenFixture.TokenJsonOverride
      }
      return ([pscustomobject]@{
        accessToken = 'offline-test-token'
        subscription = $tokenSubscription
        tenant = $tokenTenant
      } | ConvertTo-Json -Compress)
    }
    $global:LASTEXITCODE = 2
    throw 'Unexpected offline Azure CLI command.'
  }
}

Describe 'Explicit operator selectors and scoped token metadata' {
  BeforeEach {
    $script:subscriptionId = '11111111-1111-1111-1111-111111111111'
    $script:tenantId = '22222222-2222-2222-2222-222222222222'
    $global:OperatorTokenFixture = [pscustomobject]@{
      Calls = [Collections.Generic.List[object]]::new()
      AmbientSubscription = '33333333-3333-3333-3333-333333333333'
      AmbientTenant = '44444444-4444-4444-4444-444444444444'
      AccountSubscription = $script:subscriptionId
      AccountTenant = $script:tenantId
      TokenSubscription = $script:subscriptionId
      TokenTenant = $script:tenantId
      AccountJsonOverride = ''
      TokenJsonOverride = ''
      AccountExitCode = 0
      TokenExitCode = 0
      AccountStderr = $false
      TokenStderr = $false
      HttpCalls = [Collections.Generic.List[object]]::new()
    }
    $script:previousSubscription = [Environment]::GetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', 'Process')
    $script:previousTenant = [Environment]::GetEnvironmentVariable('AZURE_TENANT_ID', 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $null, 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', $null, 'Process')
  }
  AfterEach {
    [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $script:previousSubscription, 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', $script:previousTenant, 'Process')
  }
  It 'rejects a missing tenant before any Azure CLI call' {
    { Get-AuditOperatorTargetSelector -Name 'AZURE_TENANT_ID' -AzdValues @{} } | Should -Throw '*explicit GUID*'
    $global:OperatorTokenFixture.Calls.Count | Should -Be 0
  }

  It 'rejects conflicting process and selected-environment selectors' {
    [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', '33333333-3333-3333-3333-333333333333', 'Process')
    { Get-AuditOperatorTargetSelector -Name 'AZURE_TENANT_ID' -AzdValues @{ AZURE_TENANT_ID = $script:tenantId } } | Should -Throw '*do not match*'
    $global:OperatorTokenFixture.Calls.Count | Should -Be 0
  }

  It 'reads account details for the explicit subscription and verifies the tenant' {
    $account = Get-AuditOperatorAccount -SubscriptionId $script:subscriptionId -TenantId $script:tenantId
    $account.user.name | Should -BeExactly 'operator@example.test'
    @($global:OperatorTokenFixture.Calls[0].Args) | Should -Contain '--subscription'
    @($global:OperatorTokenFixture.Calls[0].Args) | Should -Contain $script:subscriptionId
  }

  It 'requests a Graph token with the explicit subscription and returns only the token value' {
    $token = Get-AuditScopedAccessToken -ResourceUrl 'https://graph.microsoft.com' -SubscriptionId $script:subscriptionId -TenantId $script:tenantId
    $token | Should -BeExactly 'offline-test-token'
    $accountArgs = @($global:OperatorTokenFixture.Calls[0].Args)
    $tokenArgs = @($global:OperatorTokenFixture.Calls[-1].Args)
    $accountArgs | Should -Contain '--subscription'
    $accountArgs | Should -Contain $script:subscriptionId
    $tokenArgs | Should -Contain '--subscription'
    $tokenArgs | Should -Contain $script:subscriptionId
    $tokenArgs | Should -Not -Contain '--tenant'
    $tokenArgs | Should -Contain '--resource'
    $tokenArgs | Should -Contain 'https://graph.microsoft.com'
    $global:OperatorTokenFixture.TokenSubscription | Should -BeExactly $script:subscriptionId
    $global:OperatorTokenFixture.AmbientSubscription | Should -Not -BeExactly $script:subscriptionId
    $global:OperatorTokenFixture.AmbientTenant | Should -Not -BeExactly $script:tenantId
  }

  It 'can bind the explicitly selected operator identity around token acquisition' {
    $context = Get-AuditScopedAccessToken -ResourceUrl 'https://management.azure.com' -SubscriptionId $script:subscriptionId -TenantId $script:tenantId -IncludeOperatorIdentity

    $context.AccessToken | Should -BeExactly 'offline-test-token'
    $context.OperatorIdentity | Should -BeExactly 'operator@example.test'
    @($global:OperatorTokenFixture.Calls | Where-Object { $_.Args[0] -eq 'account' -and $_.Args[1] -eq 'show' }).Count | Should -Be 2
  }

  It 'uses only the selected subscription for every vetted token audience, not the ambient account' {
    foreach ($resource in @(
        'https://management.azure.com',
        'https://graph.microsoft.com',
        'https://outlook.office365.com',
        'https://ps.compliance.protection.outlook.com'
      )) {
      $global:OperatorTokenFixture.Calls.Clear()
      $token = Get-AuditScopedAccessToken -ResourceUrl $resource -SubscriptionId $script:subscriptionId -TenantId $script:tenantId
      $token | Should -BeExactly 'offline-test-token'
      $tokenArgs = @($global:OperatorTokenFixture.Calls[-1].Args)
      $tokenArgs | Should -Contain '--subscription'
      $tokenArgs | Should -Contain $script:subscriptionId
      $tokenArgs | Should -Not -Contain '--tenant'
      $tokenArgs | Should -Contain '--resource'
      $tokenArgs | Should -Contain $resource
    }
  }

  It 'fails closed when Azure CLI returns a token for the wrong tenant' {
    $global:OperatorTokenFixture.TokenTenant = '33333333-3333-3333-3333-333333333333'
    try { Get-AuditScopedAccessToken -ResourceUrl 'https://graph.microsoft.com' -SubscriptionId $script:subscriptionId -TenantId $script:tenantId; throw 'Expected a tenant mismatch.' }
    catch {
      $_.Exception.Data['AuditOperatorContext'] | Should -BeTrue
      $_.Exception.Message | Should -Match 'metadata does not match'
    }
  }

  It 'fails closed when Azure CLI returns a token for the wrong subscription' {
    $global:OperatorTokenFixture.TokenSubscription = '33333333-3333-3333-3333-333333333333'
    { Get-AuditScopedAccessToken -ResourceUrl 'https://management.azure.com' -SubscriptionId $script:subscriptionId -TenantId $script:tenantId } | Should -Throw '*metadata does not match*'
  }

  It 'rejects account JSON null, scalar, empty and singleton arrays, and wrong property types' {
    $validAccount = [pscustomobject]@{
      id = $script:subscriptionId
      tenantId = $script:tenantId
      user = [pscustomobject]@{ name = 'operator@example.test' }
    }
    $singleAccountArray = ConvertTo-Json -InputObject @($validAccount) -Compress
    $wrongTypeAccount = ConvertTo-Json -InputObject ([pscustomobject]@{
      id = 42
      tenantId = $script:tenantId
      user = [pscustomobject]@{ name = 'operator@example.test' }
    }) -Compress
    foreach ($response in @('null', '"not-an-object"', '[]', $singleAccountArray, $wrongTypeAccount)) {
      $global:OperatorTokenFixture.AccountJsonOverride = $response
      try { Get-AuditOperatorAccount -SubscriptionId $script:subscriptionId -TenantId $script:tenantId; throw 'Expected malformed account metadata.' }
      catch { $_.Exception.Data['AuditOperatorContext'] | Should -BeTrue }
    }
  }

  It 'rejects token JSON null, scalar, empty and singleton arrays, and wrong property types' {
    $validToken = [pscustomobject]@{
      accessToken = 'offline-test-token'
      subscription = $script:subscriptionId
      tenant = $script:tenantId
    }
    $singleTokenArray = ConvertTo-Json -InputObject @($validToken) -Compress
    $wrongTypeToken = ConvertTo-Json -InputObject ([pscustomobject]@{
      accessToken = 123
      subscription = $script:subscriptionId
      tenant = $script:tenantId
    }) -Compress
    foreach ($response in @('null', '"not-an-object"', '[]', $singleTokenArray, $wrongTypeToken)) {
      $global:OperatorTokenFixture.TokenJsonOverride = $response
      try { Get-AuditScopedAccessToken -ResourceUrl 'https://graph.microsoft.com' -SubscriptionId $script:subscriptionId -TenantId $script:tenantId; throw 'Expected malformed token metadata.' }
      catch { $_.Exception.Data['AuditOperatorContext'] | Should -BeTrue }
    }
  }

  It 'suppresses account and token CLI stderr while retaining safe failure messages' {
    $global:OperatorTokenFixture.AccountStderr = $true
    $global:OperatorTokenFixture.AccountExitCode = 2
    $accountFailure = $null
    try { Get-AuditOperatorAccount -SubscriptionId $script:subscriptionId -TenantId $script:tenantId }
    catch { $accountFailure = $_.Exception.Message }
    $accountFailure | Should -BeExactly 'Could not read the explicitly selected Azure CLI account.'
    $accountFailure | Should -Not -Match 'SYNTHETIC_ACCOUNT_STDERR_SECRET'

    $global:OperatorTokenFixture.AccountExitCode = 0
    $global:OperatorTokenFixture.AccountStderr = $false
    $global:OperatorTokenFixture.TokenStderr = $true
    $global:OperatorTokenFixture.TokenExitCode = 2
    $tokenFailure = $null
    try { Get-AuditScopedAccessToken -ResourceUrl 'https://graph.microsoft.com' -SubscriptionId $script:subscriptionId -TenantId $script:tenantId }
    catch { $tokenFailure = $_.Exception.Message }
    $tokenFailure | Should -BeExactly "Could not acquire a scoped Azure CLI token for 'https://graph.microsoft.com'."
    $tokenFailure | Should -Not -Match 'SYNTHETIC_TOKEN_STDERR_SECRET'
  }
}

Describe 'Actual postprovision and Common token consumers' {
  BeforeEach {
    $script:subscriptionId = '11111111-1111-1111-1111-111111111111'
    $script:tenantId = '22222222-2222-2222-2222-222222222222'
    $global:OperatorTokenFixture = [pscustomobject]@{
      Calls = [Collections.Generic.List[object]]::new()
      AmbientSubscription = '33333333-3333-3333-3333-333333333333'
      AmbientTenant = '44444444-4444-4444-4444-444444444444'
      AccountSubscription = $script:subscriptionId
      AccountTenant = $script:tenantId
      TokenSubscription = $script:subscriptionId
      TokenTenant = $script:tenantId
      AccountJsonOverride = ''
      TokenJsonOverride = ''
      AccountExitCode = 0
      TokenExitCode = 0
      AccountStderr = $false
      TokenStderr = $false
      HttpCalls = [Collections.Generic.List[object]]::new()
    }
    $script:previousSubscription = [Environment]::GetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', 'Process')
    $script:previousTenant = [Environment]::GetEnvironmentVariable('AZURE_TENANT_ID', 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $null, 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', $null, 'Process')
  }
  AfterEach {
    [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $script:previousSubscription, 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', $script:previousTenant, 'Process')
  }
  It 'passes the selected context through Graph without writing the token to output' {
    & {
      . $script:postprovisionDefinitions
      $script:AuditOperatorSubscriptionId = $script:subscriptionId
      $script:AuditOperatorTenantId = $script:tenantId
      function Invoke-RestMethod {
        param($Method, $Uri, $Headers)
        $global:OperatorTokenFixture.HttpCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Authorization = $Headers.Authorization })
        [pscustomobject]@{ value = @([pscustomobject]@{ id = 'fixture' }) }
      }
      $output = @(Invoke-GraphRest -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/domains')
      $output.Count | Should -Be 1
      $output[0].value[0].id | Should -BeExactly 'fixture'
      $global:OperatorTokenFixture.HttpCalls.Count | Should -Be 1
      $global:OperatorTokenFixture.HttpCalls[0].Authorization | Should -BeExactly 'Bearer offline-test-token'
      $tokenArgs = @($global:OperatorTokenFixture.Calls[-1].Args)
      $tokenArgs | Should -Contain '--subscription'
      $tokenArgs | Should -Contain $script:subscriptionId
      $tokenArgs | Should -Not -Contain '--tenant'
    }

  }

  It 'stops Graph domain fallback on a token-context mismatch' {
    $global:OperatorTokenFixture.TokenTenant = '33333333-3333-3333-3333-333333333333'
    & {
      . $script:postprovisionDefinitions
      $script:AuditOperatorSubscriptionId = $script:subscriptionId
      $script:AuditOperatorTenantId = $script:tenantId
      function Invoke-RestMethod { throw 'HTTP must not be reached.' }
      function Get-AcceptedDomain { throw 'Domain fallback must not be reached.' }
      try { Get-ExchangeOrganizationDomain; throw 'Expected a token-context failure.' }
      catch {
        $_.Exception.Data['AuditOperatorContext'] | Should -BeTrue
        $_.Exception.Message | Should -Match 'metadata does not match'
      }
      $global:OperatorTokenFixture.HttpCalls.Count | Should -Be 0
    }
  }

  It 'does not use the browser fallback when selected-account metadata is wrong' {
    $global:OperatorTokenFixture.AccountTenant = '33333333-3333-3333-3333-333333333333'
    & {
      . $script:postprovisionDefinitions
      $script:AuditOperatorSubscriptionId = $script:subscriptionId
      $script:AuditOperatorTenantId = $script:tenantId
      function Connect-ExchangeOnline { $global:OperatorTokenFixture.HttpCalls.Add('connection') }
      { Connect-ExchangeForBootstrap } | Should -Throw '*metadata does not match*'
      $global:OperatorTokenFixture.HttpCalls.Count | Should -Be 0
    }
  }

  It 'does not use the browser fallback when selected-account JSON is null' {
    $global:OperatorTokenFixture.AccountJsonOverride = 'null'
    & {
      . $script:postprovisionDefinitions
      $script:AuditOperatorSubscriptionId = $script:subscriptionId
      $script:AuditOperatorTenantId = $script:tenantId
      function Connect-ExchangeOnline { $global:OperatorTokenFixture.HttpCalls.Add('connection') }
      try { Connect-ExchangeForBootstrap; throw 'Expected malformed account metadata.' }
      catch { $_.Exception.Data['AuditOperatorContext'] | Should -BeTrue }
      $global:OperatorTokenFixture.HttpCalls.Count | Should -Be 0
    }
  }

  It 'does not use the browser fallback when token JSON is null' {
    $global:OperatorTokenFixture.TokenJsonOverride = 'null'
    & {
      . $script:postprovisionDefinitions
      $script:AuditOperatorSubscriptionId = $script:subscriptionId
      $script:AuditOperatorTenantId = $script:tenantId
      function Connect-ExchangeOnline { $global:OperatorTokenFixture.HttpCalls.Add('connection') }
      try { Connect-ExchangeForBootstrap; throw 'Expected malformed token metadata.' }
      catch { $_.Exception.Data['AuditOperatorContext'] | Should -BeTrue }
      $global:OperatorTokenFixture.HttpCalls.Count | Should -Be 0
    }
  }

  It 'does not use cached-domain fallback when token JSON is null' {
    $global:OperatorTokenFixture.TokenJsonOverride = 'null'
    & {
      . $script:postprovisionDefinitions
      $script:AuditOperatorSubscriptionId = $script:subscriptionId
      $script:AuditOperatorTenantId = $script:tenantId
      function Invoke-RestMethod { throw 'HTTP must not be reached.' }
      function Get-AcceptedDomain { $global:OperatorTokenFixture.HttpCalls.Add('accepted-domain') }
      try { Get-ExchangeOrganizationDomain; throw 'Expected malformed token metadata.' }
      catch { $_.Exception.Data['AuditOperatorContext'] | Should -BeTrue }
      $global:OperatorTokenFixture.HttpCalls | Should -Not -Contain 'accepted-domain'
    }
  }

  It 'does not issue an ARM PUT when the returned scoped token metadata differs' {
    $global:OperatorTokenFixture.TokenSubscription = '33333333-3333-3333-3333-333333333333'
    & {
      $script:writes = 0
      function Invoke-RestMethod { $script:writes++ }
      { Set-AutomationVariableValue -SubscriptionId $script:subscriptionId -TenantId $script:tenantId -ResourceGroupName 'fixture-rg' -AutomationAccountName 'fixture-aa' -VariableName 'fixture' -Value 'safe' } | Should -Throw '*metadata does not match*'
      $script:writes | Should -Be 0
      $tokenArgs = @($global:OperatorTokenFixture.Calls[-1].Args)
      $tokenArgs | Should -Contain $script:subscriptionId
      $tokenArgs | Should -Not -Contain '--tenant'
      $tokenArgs | Should -Contain 'https://management.azure.com'
    }
  }

  It 'does not issue an ARM PUT when token JSON is null' {
    $global:OperatorTokenFixture.TokenJsonOverride = 'null'
    & {
      $script:writes = 0
      function Invoke-RestMethod { $script:writes++ }
      try { Set-AutomationVariableValue -SubscriptionId $script:subscriptionId -TenantId $script:tenantId -ResourceGroupName 'fixture-rg' -AutomationAccountName 'fixture-aa' -VariableName 'fixture' -Value 'safe'; throw 'Expected malformed token metadata.' }
      catch { $_.Exception.Data['AuditOperatorContext'] | Should -BeTrue }
      $script:writes | Should -Be 0
    }
  }

  It 'binds the token context before the first postprovision ownership receipt write' {
    $source = Get-Content "$script:repoRoot/hooks/postprovision.ps1" -Raw
    $targetRead = $source.IndexOf("-ResourceUrl 'https://management.azure.com' | Out-Null")
    $firstReceiptWrite = $source.IndexOf("Set-AzdEnvironmentValue -Name 'AUTOMATION_OWNED_ACCOUNT_ID'")
    $targetRead | Should -BeGreaterThan -1
    $firstReceiptWrite | Should -BeGreaterThan $targetRead

    $common = Get-Content "$script:repoRoot/hooks/Common.ps1" -Raw
    $accountMapping = $common.IndexOf('$account = Get-AuditOperatorAccount -SubscriptionId $SubscriptionId -TenantId $TenantId')
    $tokenRequest = $common.IndexOf('$tokenJson = & az @tokenArguments 2>$null')
    $accountMapping | Should -BeGreaterThan -1
    $tokenRequest | Should -BeGreaterThan $accountMapping
  }
}

AfterAll {
  Remove-Variable -Name OperatorTokenFixture -Scope Global -ErrorAction SilentlyContinue
}
