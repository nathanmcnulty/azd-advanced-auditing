Describe 'Automation jobSchedule ownership' {
  BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks/JobScheduleOwnership.ps1')
    $script:accountId = '/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Automation/automationAccounts/aa-1'
    $script:principalId = '11111111-1111-1111-1111-111111111111'
    $script:ownedId = '22222222-2222-2222-2222-222222222222'
    $script:unrelatedId = '33333333-3333-3333-3333-333333333333'
    $script:account = [pscustomobject]@{ id = $script:accountId; identity = [pscustomobject]@{ principalId = $script:principalId } }
    $script:owned = [pscustomobject]@{ name = $script:ownedId; properties = [pscustomobject]@{ jobScheduleId = $script:ownedId; schedule = @{ name = 'advanced-auditing-daily' }; runbook = @{ name = 'Enable-AdvancedAuditing' } } }
    $script:unrelated = [pscustomobject]@{ name = $script:unrelatedId; properties = [pscustomobject]@{ jobScheduleId = $script:unrelatedId; schedule = @{ name = 'unrelated-daily' }; runbook = @{ name = 'Other-Runbook' } } }
  }

  It 'selects only the receipt-bound template schedule in a mixed account' {
    $result = Resolve-AuditJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account `
      -JobSchedules @($script:unrelated, $script:owned) -ReceiptAccountId $script:accountId `
      -ReceiptPrincipalId $script:principalId -ReceiptJobScheduleId $script:ownedId
    $result.OwnedJobScheduleId | Should -Be $script:ownedId
    $result.JobScheduleId | Should -Be $script:ownedId
  }

  It 'fails closed for an existing account without a receipt or adoption' {
    { Resolve-AuditJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account -JobSchedules @($script:unrelated, $script:owned) } | Should -Throw '*Explicit adoption*'
  }

  It 'requires exact account principal and schedule identifiers for adoption' {
    $adopt = @{ ExpectedAccountId = $script:accountId; Account = $script:account; JobSchedules = @($script:unrelated, $script:owned); AdoptAccountId = $script:accountId; AdoptPrincipalId = $script:principalId }
    { Resolve-AuditJobScheduleOwnership @adopt } | Should -Throw '*exact ID*'
    $adopt.AdoptJobScheduleId = $script:ownedId
    (Resolve-AuditJobScheduleOwnership @adopt).OwnedJobScheduleId | Should -Be $script:ownedId
  }

  It 'rejects a stale receipt after account identity changes' {
    { Resolve-AuditJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account -JobSchedules @($script:owned) `
        -ReceiptAccountId $script:accountId -ReceiptPrincipalId '44444444-4444-4444-4444-444444444444' -ReceiptJobScheduleId $script:ownedId } | Should -Throw '*receipt does not match*'
  }

  It 'rejects a partial ownership receipt and a reused template schedule name' {
    { Resolve-AuditJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account -JobSchedules @($script:owned) `
        -ReceiptAccountId $script:accountId -AdoptAccountId $script:accountId -AdoptPrincipalId $script:principalId -AdoptJobScheduleId $script:ownedId } | Should -Throw '*receipt is incomplete*'
    $wrongRunbook = [pscustomobject]@{ name = $script:unrelatedId; properties = [pscustomobject]@{ jobScheduleId = $script:unrelatedId; schedule = @{ name = 'advanced-auditing-daily' }; runbook = @{ name = 'Other-Runbook' } } }
    { Resolve-AuditJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account -JobSchedules @($wrongRunbook) `
        -AdoptAccountId $script:accountId -AdoptPrincipalId $script:principalId } | Should -Throw '*unexpected runbook*'
  }

  It 'rejects an ID collision with an unrelated schedule and ambiguous duplicate links' {
    { Resolve-AuditJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account -JobSchedules @($script:unrelated) `
        -ReceiptAccountId $script:accountId -ReceiptPrincipalId $script:principalId -ReceiptJobScheduleId $script:unrelatedId } | Should -Throw '*belongs to a different*'
    $secondOwned = [pscustomobject]@{ name = '55555555-5555-5555-5555-555555555555'; properties = [pscustomobject]@{ jobScheduleId = '55555555-5555-5555-5555-555555555555'; schedule = @{ name = 'advanced-auditing-daily' }; runbook = @{ name = 'Enable-AdvancedAuditing' } } }
    { Resolve-AuditJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account -JobSchedules @($script:owned, $secondOwned) `
        -ReceiptAccountId $script:accountId -ReceiptPrincipalId $script:principalId -ReceiptJobScheduleId $script:ownedId } | Should -Throw '*More than one*'
  }

  It 'starts with a fresh ID after account deletion rather than trusting a stale receipt' {
    $result = Resolve-AuditJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $null -JobSchedules @() `
      -ReceiptAccountId $script:accountId -ReceiptPrincipalId $script:principalId -ReceiptJobScheduleId $script:ownedId
    ([string]$result.OwnedJobScheduleId).Length | Should -Be 0
    $result.JobScheduleId | Should -Not -Be $script:ownedId
    (Test-AuditGuid -Value $result.JobScheduleId) | Should -BeTrue
  }

  It 'records a receipt only for the exact provisioned association' {
    { Assert-AuditOwnershipReceiptTarget -ExpectedAccountId $script:accountId -ExpectedPrincipalId $script:principalId `
        -ExpectedJobScheduleId $script:ownedId -Account $script:account -JobSchedule $script:owned } | Should -Not -Throw
    { Assert-AuditOwnershipReceiptTarget -ExpectedAccountId $script:accountId -ExpectedPrincipalId $script:principalId `
        -ExpectedJobScheduleId $script:unrelatedId -Account $script:account -JobSchedule $script:owned } | Should -Throw '*does not match*'
  }
}

Describe 'Exchange bootstrap fallback' {
  BeforeAll {
    $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks/postprovision.ps1'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Connect-ExchangeForBootstrap' }, $true)
    $script:connectDefinition = [scriptblock]::Create($definition.Extent.Text)
  }

  It 'uses the selected UPN and no device flow when token connection fails' {
    & {
      . $script:connectDefinition
      function Get-AzCliUserPrincipalName { 'operator@example.com' }
      function Get-AzCliAccessToken { 'offline-token' }
      function Connect-ExchangeOnline {
        param([string]$AccessToken, [string]$UserPrincipalName, [bool]$ShowBanner, [switch]$Device)
        if ($PSBoundParameters.ContainsKey('AccessToken')) { throw 'token unavailable' }
        $script:fallbackParameters = @{} + $PSBoundParameters
      }
      Connect-ExchangeForBootstrap
      $script:fallbackParameters.UserPrincipalName | Should -Be 'operator@example.com'
      $script:fallbackParameters.ContainsKey('Device') | Should -BeFalse
    }
  }

  It 'reports a blocker if normal cached or browser sign-in cannot complete' {
    & {
      . $script:connectDefinition
      function Get-AzCliUserPrincipalName { 'operator@example.com' }
      function Get-AzCliAccessToken { 'offline-token' }
      function Connect-ExchangeOnline { throw 'offline auth unavailable' }
      { Connect-ExchangeForBootstrap } | Should -Throw '*cached or browser sign-in*'
    }
  }

  It 'falls back to standard account sign-in if Azure CLI cannot issue an Outlook token' {
    & {
      . $script:connectDefinition
      function Get-AzCliUserPrincipalName { 'operator@example.com' }
      function Get-AzCliAccessToken { throw 'token unavailable' }
      function Connect-ExchangeOnline {
        param([string]$AccessToken, [string]$UserPrincipalName, [bool]$ShowBanner, [switch]$Device)
        $script:fallbackParameters = @{} + $PSBoundParameters
      }
      Connect-ExchangeForBootstrap
      $script:fallbackParameters.UserPrincipalName | Should -Be 'operator@example.com'
      $script:fallbackParameters.ContainsKey('AccessToken') | Should -BeFalse
      $script:fallbackParameters.ContainsKey('Device') | Should -BeFalse
    }
  }
}

Describe 'Preprovision preserves existing schedule linkage' {
  BeforeAll {
    $script:hookPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks/preprovision.ps1'
    $script:accountId = '/subscriptions/sub-1/resourceGroups/rg-offline/providers/Microsoft.Automation/automationAccounts/aaauditoffline'
    $script:principalId = '11111111-1111-1111-1111-111111111111'
    $script:scheduleId = '22222222-2222-2222-2222-222222222222'
  }

  It 'leaves the prior linkage and lock intact before a failed ARM redeployment' {
    & {
      $names = @('AZURE_ENV_NAME','AZURE_SUBSCRIPTION_ID','AZURE_RESOURCE_GROUP','AUTOMATION_ACCOUNT_NAME','AUTOMATION_JOB_SCHEDULE_ID','DEPLOYMENT_TIMESTAMP','AUTOMATION_OWNED_ACCOUNT_ID','AUTOMATION_OWNED_PRINCIPAL_ID','AUTOMATION_OWNED_JOB_SCHEDULE_ID')
      $saved = @{}
      foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
      try {
        [Environment]::SetEnvironmentVariable('AZURE_ENV_NAME', 'offline')
        [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', 'sub-1')
        [Environment]::SetEnvironmentVariable('AZURE_RESOURCE_GROUP', 'rg-offline')
        [Environment]::SetEnvironmentVariable('AUTOMATION_OWNED_ACCOUNT_ID', $script:accountId)
        [Environment]::SetEnvironmentVariable('AUTOMATION_OWNED_PRINCIPAL_ID', $script:principalId)
        [Environment]::SetEnvironmentVariable('AUTOMATION_OWNED_JOB_SCHEDULE_ID', $script:scheduleId)
        $global:testAzureCalls = [Collections.Generic.List[string]]::new()
        $global:testAccountId = $script:accountId
        $global:testPrincipalId = $script:principalId
        $global:testScheduleId = $script:scheduleId
        function azd {
          if ($args[0] -eq 'env' -and $args[1] -eq 'get-values') { $global:LASTEXITCODE = 0; return 'AZURE_ENV_NAME=offline' }
          if ($args[0] -eq 'env' -and $args[1] -eq 'set') { $global:LASTEXITCODE = 0; return }
          throw "Unexpected azd command: $($args -join ' ')"
        }
        function az {
          $command = $args -join ' '
          $global:testAzureCalls.Add($command)
          $global:LASTEXITCODE = 0
          if ($command -like 'group exists *') { return 'true' }
          if ($command -like 'automation account list *') { return '[{"name":"aaauditoffline"}]' }
          if ($command -like 'automation account show *') { return ('{{"id":"{0}","identity":{{"principalId":"{1}"}}}}' -f $global:testAccountId,$global:testPrincipalId) }
          if ($command -like 'rest --method GET *') { return ('{{"value":[{{"name":"{0}","properties":{{"jobScheduleId":"{0}","schedule":{{"name":"advanced-auditing-daily"}},"runbook":{{"name":"Enable-AdvancedAuditing"}}}}}}]}}' -f $global:testScheduleId) }
          throw "Unexpected Azure command: $command"
        }
        & $script:hookPath
        { throw 'simulated ARM failure' } | Should -Throw '*simulated ARM failure*'
        @($global:testAzureCalls | Where-Object { $_ -match 'DELETE|lock delete|lock create' }).Count | Should -Be 0
        [Environment]::GetEnvironmentVariable('AUTOMATION_JOB_SCHEDULE_ID') | Should -Be $script:scheduleId
      }
      finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        Remove-Variable testAzureCalls,testAccountId,testPrincipalId,testScheduleId -Scope Global -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
      }
    }
  }

  It 'rejects a mismatched receipt before any Azure mutation' {
    & {
      $names = @('AZURE_ENV_NAME','AZURE_SUBSCRIPTION_ID','AZURE_RESOURCE_GROUP','AUTOMATION_ACCOUNT_NAME','AUTOMATION_JOB_SCHEDULE_ID','DEPLOYMENT_TIMESTAMP','AUTOMATION_OWNED_ACCOUNT_ID','AUTOMATION_OWNED_PRINCIPAL_ID','AUTOMATION_OWNED_JOB_SCHEDULE_ID')
      $saved = @{}
      foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
      try {
        [Environment]::SetEnvironmentVariable('AZURE_ENV_NAME', 'offline')
        [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', 'sub-1')
        [Environment]::SetEnvironmentVariable('AZURE_RESOURCE_GROUP', 'rg-offline')
        [Environment]::SetEnvironmentVariable('AUTOMATION_OWNED_ACCOUNT_ID', $script:accountId)
        [Environment]::SetEnvironmentVariable('AUTOMATION_OWNED_PRINCIPAL_ID', '99999999-9999-9999-9999-999999999999')
        [Environment]::SetEnvironmentVariable('AUTOMATION_OWNED_JOB_SCHEDULE_ID', $script:scheduleId)
        $global:testAzureCalls = [Collections.Generic.List[string]]::new()
        $global:testAccountId = $script:accountId
        $global:testPrincipalId = $script:principalId
        $global:testScheduleId = $script:scheduleId
        function azd {
          if ($args[0] -eq 'env' -and $args[1] -eq 'get-values') { $global:LASTEXITCODE = 0; return 'AZURE_ENV_NAME=offline' }
          if ($args[0] -eq 'env' -and $args[1] -eq 'set') { $global:LASTEXITCODE = 0; return }
          throw "Unexpected azd command: $($args -join ' ')"
        }
        function az {
          $command = $args -join ' '
          $global:testAzureCalls.Add($command)
          $global:LASTEXITCODE = 0
          if ($command -like 'group exists *') { return 'true' }
          if ($command -like 'automation account list *') { return '[{"name":"aaauditoffline"}]' }
          if ($command -like 'automation account show *') { return ('{{"id":"{0}","identity":{{"principalId":"{1}"}}}}' -f $global:testAccountId,$global:testPrincipalId) }
          if ($command -like 'rest --method GET *') { return ('{{"value":[{{"name":"{0}","properties":{{"jobScheduleId":"{0}","schedule":{{"name":"advanced-auditing-daily"}},"runbook":{{"name":"Enable-AdvancedAuditing"}}}}}}]}}' -f $global:testScheduleId) }
          throw "Unexpected Azure command: $command"
        }
        { & $script:hookPath } | Should -Throw '*receipt does not match*'
        @($global:testAzureCalls | Where-Object { $_ -match 'DELETE|lock delete|lock create' }).Count | Should -Be 0
      }
      finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        Remove-Variable testAzureCalls,testAccountId,testPrincipalId,testScheduleId -Scope Global -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
      }
    }
  }
}
