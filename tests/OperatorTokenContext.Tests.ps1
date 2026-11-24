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
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'account' -and $args[1] -eq 'show') {
      return ([pscustomobject]@{
        id = $global:OperatorTokenFixture.AccountSubscription
        tenantId = $global:OperatorTokenFixture.AccountTenant
        user = [pscustomobject]@{ name = 'operator@example.test' }
      } | ConvertTo-Json -Compress)
    }
    if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') {
      return ([pscustomobject]@{
        accessToken = 'offline-test-token'
        subscription = $global:OperatorTokenFixture.TokenSubscription
        tenant = $global:OperatorTokenFixture.TokenTenant
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
      AccountSubscription = $script:subscriptionId
      AccountTenant = $script:tenantId
      TokenSubscription = $script:subscriptionId
      TokenTenant = $script:tenantId
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

  It 'requests a token with explicit selectors and returns only the token value to its caller' {
    $token = Get-AuditScopedAccessToken -ResourceUrl 'https://graph.microsoft.com' -SubscriptionId $script:subscriptionId -TenantId $script:tenantId
    $token | Should -BeExactly 'offline-test-token'
    $tokenArgs = @($global:OperatorTokenFixture.Calls[0].Args)
    $tokenArgs | Should -Contain '--subscription'
    $tokenArgs | Should -Contain $script:subscriptionId
    $tokenArgs | Should -Contain '--tenant'
    $tokenArgs | Should -Contain $script:tenantId
    $tokenArgs | Should -Contain '--resource'
    $tokenArgs | Should -Contain 'https://graph.microsoft.com'
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
}

Describe 'Actual postprovision and Common token consumers' {
  BeforeEach {
    $script:subscriptionId = '11111111-1111-1111-1111-111111111111'
    $script:tenantId = '22222222-2222-2222-2222-222222222222'
    $global:OperatorTokenFixture = [pscustomobject]@{
      Calls = [Collections.Generic.List[object]]::new()
      AccountSubscription = $script:subscriptionId
      AccountTenant = $script:tenantId
      TokenSubscription = $script:subscriptionId
      TokenTenant = $script:tenantId
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
      $tokenArgs = @($global:OperatorTokenFixture.Calls[0].Args)
      $tokenArgs | Should -Contain $script:subscriptionId
      $tokenArgs | Should -Contain $script:tenantId
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

  It 'does not issue an ARM PUT when the returned scoped token metadata differs' {
    $global:OperatorTokenFixture.TokenSubscription = '33333333-3333-3333-3333-333333333333'
    & {
      $script:writes = 0
      function Invoke-RestMethod { $script:writes++ }
      { Set-AutomationVariableValue -SubscriptionId $script:subscriptionId -TenantId $script:tenantId -ResourceGroupName 'fixture-rg' -AutomationAccountName 'fixture-aa' -VariableName 'fixture' -Value 'safe' } | Should -Throw '*metadata does not match*'
      $script:writes | Should -Be 0
      $tokenArgs = @($global:OperatorTokenFixture.Calls[0].Args)
      $tokenArgs | Should -Contain $script:subscriptionId
      $tokenArgs | Should -Contain $script:tenantId
      $tokenArgs | Should -Contain 'https://management.azure.com'
    }
  }

  It 'binds the token context before the first postprovision ownership receipt write' {
    $source = Get-Content "$script:repoRoot/hooks/postprovision.ps1" -Raw
    $targetRead = $source.IndexOf('$operatorAccount = Get-AuditOperatorAccount')
    $scopedToken = $source.IndexOf("-ResourceUrl 'https://management.azure.com'", $targetRead)
    $firstReceiptWrite = $source.IndexOf("Set-AzdEnvironmentValue -Name 'AUTOMATION_OWNED_ACCOUNT_ID'", $targetRead)
    $targetRead | Should -BeGreaterThan -1
    $scopedToken | Should -BeGreaterThan $targetRead
    $firstReceiptWrite | Should -BeGreaterThan $scopedToken
  }
}

AfterAll {
  Remove-Variable -Name OperatorTokenFixture -Scope Global -ErrorAction SilentlyContinue
}
