Describe 'Advanced auditing template' {
  BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $bicepPath = Join-Path $repoRoot 'infra\main.bicep'
    $parametersPath = Join-Path $repoRoot 'infra\main.parameters.json'
    $azureYamlPath = Join-Path $repoRoot 'azure.yaml'
    $validationRunbookPath = Join-Path $repoRoot 'runbooks\Validate-AdvancedAuditingConfiguration.ps1'

    $bicep = Get-Content -Path $bicepPath -Raw
    $parameters = Get-Content -Path $parametersPath -Raw | ConvertFrom-Json
    $azureYaml = Get-Content -Path $azureYamlPath -Raw
    $validationRunbook = Get-Content -Path $validationRunbookPath -Raw
  }

  It 'uses a supported PowerShell runtime for ExchangeOnlineManagement 3.10.1' {
    $bicep | Should -Match "version: '7\.6'"
    $bicep | Should -Match 'ExchangeOnlineManagement/3\.10\.1'
  }

  It 'maps all values prepared by preprovision into Bicep parameters' {
    $parameters.parameters.environmentName.value | Should -Be '${AZURE_ENV_NAME}'
    $parameters.parameters.automationAccountName.value | Should -Be '${AUTOMATION_ACCOUNT_NAME}'
    $parameters.parameters.deploymentTimestamp.value | Should -Be '${DEPLOYMENT_TIMESTAMP}'
    $parameters.parameters.jobScheduleId.value | Should -Be '${AUTOMATION_JOB_SCHEDULE_ID}'
  }

  It 'removes the resource lock before azd teardown' {
    $azureYaml | Should -Match '(?m)^  predown:'
    $azureYaml | Should -Match ([regex]::Escape('run: .\hooks\predown.ps1'))
  }

  It 'validates all mailboxes and audit bypass associations by default' {
    $validationRunbook | Should -Match '\[int\]\$SampleSize = 0'
    $validationRunbook | Should -Match 'if \(\$SampleSize -eq 0\) \{ ''Unlimited'' \}'
    $validationRunbook | Should -Match 'Get-MailboxAuditBypassAssociation -ResultSize Unlimited'
  }

  It 'keeps remediation and validation action lists aligned' {
    $enablePath = Join-Path $repoRoot 'runbooks\Enable-AdvancedAuditing.ps1'
    $enableContent = Get-Content -Path $enablePath -Raw

    foreach ($role in @('Admin', 'Delegate', 'Owner')) {
      $enablePattern = '(?s)\$audit{0}Actions = @\((?<values>.*?)\)' -f $role
      $validationPattern = '(?s)\$expected{0} = @\((?<values>.*?)\)' -f $role
      $enableMatch = [regex]::Match($enableContent, $enablePattern)
      $validationMatch = [regex]::Match($validationRunbook, $validationPattern)

      $enableMatch.Success | Should -BeTrue
      $validationMatch.Success | Should -BeTrue

      $enableValues = [regex]::Matches($enableMatch.Groups['values'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
      $validationValues = [regex]::Matches($validationMatch.Groups['values'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
      Compare-Object -ReferenceObject $enableValues -DifferenceObject $validationValues | Should -BeNullOrEmpty
    }
  }
}

Describe 'Validation runbook output privacy' {
  BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $managedIdentityRunbookPath = Join-Path $repoRoot 'runbooks\Validate-ExchangeManagedIdentity.ps1'
    $configurationRunbookPath = Join-Path $repoRoot 'runbooks\Validate-AdvancedAuditingConfiguration.ps1'
    $tokens = $null
    $parseErrors = $null
    $configurationAst = [Management.Automation.Language.Parser]::ParseFile(
      $configurationRunbookPath,
      [ref]$tokens,
      [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }

    $helperAsts = @($configurationAst.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in @('Test-ContainsAll', 'Get-AdvancedAuditingFailureSummary')
    }, $true))
    $containsAllAst = $helperAsts | Where-Object Name -eq 'Test-ContainsAll' | Select-Object -First 1
    $summaryAst = $helperAsts | Where-Object Name -eq 'Get-AdvancedAuditingFailureSummary' | Select-Object -First 1
    if (-not $containsAllAst -or -not $summaryAst) { throw 'Validation summary helpers were not found.' }
    $script:validationSummaryHelpers = [scriptblock]::Create(
      $containsAllAst.Extent.Text + [Environment]::NewLine + $summaryAst.Extent.Text
    )
  }

  It 'does not include mailbox identifiers in the managed identity success message' {
    $source = Get-Content -Path $managedIdentityRunbookPath -Raw

    $source | Should -Match "Managed identity connection succeeded; a user mailbox was returned\."
    $source | Should -Not -Match 'PrimarySmtpAddress'
  }

  It 'summarizes configuration failures using bounded counts instead of identifiers' {
    . $script:validationSummaryHelpers
    $mailboxes = @(
      [pscustomobject]@{
        PrimarySmtpAddress = 'private.first@example.invalid'
        AuditEnabled = $false
        AuditLogAgeLimit = [timespan]::FromDays(30)
        AuditAdmin = @()
        AuditDelegate = @()
        AuditOwner = @()
      }
      [pscustomobject]@{
        PrimarySmtpAddress = 'private.second@example.invalid'
        AuditEnabled = $false
        AuditLogAgeLimit = [timespan]::FromDays(90)
        AuditAdmin = @()
        AuditDelegate = @()
        AuditOwner = @()
      }
    )
    $bypassAssociations = @(
      [pscustomobject]@{ Identity = 'private.bypass@example.invalid'; AuditBypassEnabled = $true }
    )
    $summary = @(Get-AdvancedAuditingFailureSummary -Mailboxes $mailboxes -BypassAssociations $bypassAssociations `
      -ExpectedAdmin @('AdminAction') -ExpectedDelegate @('DelegateAction') -ExpectedOwner @('OwnerAction'))
    $summaryText = $summary -join '; '

    $summaryText | Should -Match 'Mailbox audit bypass enabled for 1 association\(s\)'
    $summaryText | Should -Match 'AuditEnabled=false for 2 user mailbox\(es\)'
    $summaryText | Should -Match 'AuditLogAgeLimit below 365 days for 2 user mailbox\(es\)'
    $summaryText | Should -Match 'Missing expected AuditAdmin entries for 2 user mailbox\(es\)'
    $summaryText | Should -Match 'Missing expected AuditDelegate entries for 2 user mailbox\(es\)'
    $summaryText | Should -Match 'Missing expected AuditOwner entries for 2 user mailbox\(es\)'
    $summaryText | Should -Not -Match 'private\.(first|second|bypass)@example\.invalid'
  }

  It 'returns no failure categories for compliant mailbox settings' {
    . $script:validationSummaryHelpers
    $mailboxes = @(
      [pscustomobject]@{
        AuditEnabled = $true
        AuditLogAgeLimit = [timespan]::FromDays(365)
        AuditAdmin = @('AdminAction')
        AuditDelegate = @('DelegateAction')
        AuditOwner = @('OwnerAction')
      }
    )
    $summary = @(Get-AdvancedAuditingFailureSummary -Mailboxes $mailboxes -BypassAssociations @() `
      -ExpectedAdmin @('AdminAction') -ExpectedDelegate @('DelegateAction') -ExpectedOwner @('OwnerAction'))

    $summary.Count | Should -Be 0
  }

  It 'formats validation errors without mailbox or bypass identity interpolation' {
    $source = Get-Content -Path $configurationRunbookPath -Raw

    $source | Should -Match 'Advanced auditing validation failed for \$\(\$mailboxes\.Count\) user mailbox'
    $source | Should -Not -Match '\$mailbox\.PrimarySmtpAddress'
    $source | Should -Not -Match '\$bypassAssociation\.(Identity|Name)'
  }
}

Describe 'Remediation runbook output privacy' {
  It 'reports aggregate WhatIf status while suppressing Exchange mailbox identities and return objects' {
    $runbookPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'runbooks\Enable-AdvancedAuditing.ps1'
    $previousRunbookPath = $env:AA_TEST_RUNBOOK
    $childScript = @'
$ErrorActionPreference = 'Stop'
$global:fixtureMailboxes = @(
  [pscustomobject]@{ PrimarySmtpAddress = 'private.one@example.invalid' }
  [pscustomobject]@{ PrimarySmtpAddress = 'private.two@example.invalid' }
)
$global:setMailboxCalls = @()
$global:lookupCalls = @()

function Get-Module {
  [CmdletBinding()]
  param([string]$Name, [switch]$ListAvailable)
  if ($Name -eq 'ExchangeOnlineManagement' -and $ListAvailable.IsPresent) {
    return [pscustomobject]@{ Version = [version]'3.10.1'; Path = 'offline-fixture-module' }
  }
  throw "Unexpected module lookup: $Name"
}
function Import-Module {
  [CmdletBinding()]
  param([string]$Name, [switch]$Force)
}
function Connect-ExchangeOnline {
  [CmdletBinding()]
  param([switch]$ManagedIdentity, [string]$Organization, [switch]$ShowBanner)
  if (-not $ManagedIdentity.IsPresent -or $Organization -ne 'fixture.example.invalid') {
    throw 'Unexpected Exchange connection arguments.'
  }
}
function Get-Mailbox {
  [CmdletBinding()]
  param([string]$Identity, [string]$ResultSize, [scriptblock]$Filter)
  if ($PSBoundParameters.ContainsKey('Identity')) {
    $global:lookupCalls += $Identity
    return $global:fixtureMailboxes[0]
  }
  return $global:fixtureMailboxes
}
function Set-Mailbox {
  [CmdletBinding()]
  param(
    [string]$Identity,
    [bool]$AuditEnabled,
    [int]$AuditLogAgeLimit,
    [hashtable]$AuditAdmin,
    [hashtable]$AuditDelegate,
    [hashtable]$AuditOwner,
    [switch]$WhatIf
  )
  $global:setMailboxCalls += [pscustomobject]@{ Identity = $Identity; WhatIf = $WhatIf.IsPresent }
  [pscustomobject]@{ ResultIdentity = $Identity; SyntheticResult = 'offline Exchange stub' }
}
function Disconnect-ExchangeOnline {
  [CmdletBinding()]
  param([switch]$Confirm)
}

$captured = @(& $env:AA_TEST_RUNBOOK -Organization 'fixture.example.invalid' -WhatIf)
if ($global:setMailboxCalls.Count -ne 2) { throw "Expected two stubbed Set-Mailbox calls; got $($global:setMailboxCalls.Count)." }
if (@($global:setMailboxCalls | Where-Object { -not $_.WhatIf }).Count -ne 0) { throw 'The runbook did not pass WhatIf to every stubbed Set-Mailbox call.' }
$text = ($captured | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
if ($text -notmatch 'Processing 2 user mailboxes\.') { throw 'The aggregate mailbox count was missing.' }
if ($text -notmatch 'WhatIf completed for 2 user mailboxes; no changes were applied\.') { throw 'The dry-run aggregate summary was missing.' }
if ($text -match '[^\s@]+@example\.invalid|ResultIdentity|SyntheticResult') { throw 'The runbook exposed a mailbox identifier or synthetic cmdlet return object.' }
Write-Output $text
'@

    try {
      $env:AA_TEST_RUNBOOK = $runbookPath
      $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
      $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
      $childOutput = @(& $pwshPath -NoLogo -NoProfile -EncodedCommand $encodedCommand 2>&1)
      $childExitCode = $LASTEXITCODE
    }
    finally {
      if ($null -eq $previousRunbookPath) { Remove-Item Env:AA_TEST_RUNBOOK -ErrorAction SilentlyContinue }
      else { $env:AA_TEST_RUNBOOK = $previousRunbookPath }
    }

    $childText = $childOutput -join [Environment]::NewLine
    $childExitCode | Should -Be 0 -Because $childText
    $childText | Should -Match 'Processing 2 user mailboxes\.'
    $childText | Should -Match 'WhatIf completed for 2 user mailboxes; no changes were applied\.'
    $childText | Should -Not -Match 'private\.(one|two)@example\.invalid|ResultIdentity|SyntheticResult'
  }
}

Describe 'Automation runbook publication' {
  BeforeAll {
    $commonPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks/Common.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($commonPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
    $publisher = $ast.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Publish-AutomationRunbookContent'
    }, $true)
    if (-not $publisher) { throw 'Runbook publisher was not found.' }
    $publisherDefinition = [scriptblock]::Create($publisher.Extent.Text)
  }

  It 'stops after <Name> fails' -ForEach @(
    @{ Name = 'show'; ExpectedCalls = 1; ErrorText = 'inspect' }
    @{ Name = 'replace-content'; ExpectedCalls = 2; ErrorText = 'replace content' }
    @{ Name = 'publish'; ExpectedCalls = 3; ErrorText = 'publish' }
  ) {
    & {
      . $publisherDefinition
      $filePath = Join-Path $TestDrive 'runbook.ps1'
      Set-Content -LiteralPath $filePath -Value 'Write-Output "fixture"'
      $script:publisherCalls = [System.Collections.Generic.List[string]]::new()
      $failedCommand = $Name
      function az {
        $commandName = [string]$args[2]
        $script:publisherCalls.Add($commandName)
        $global:LASTEXITCODE = if ($commandName -eq $failedCommand) { 7 } else { 0 }
      }
      try {
        {
          Publish-AutomationRunbookContent -SubscriptionId 'test-subscription' -ResourceGroupName 'test-group' `
            -AutomationAccountName 'test-automation' -RunbookName 'test-runbook' -FilePath $filePath
        } | Should -Throw "*$ErrorText*"
        $script:publisherCalls.Count | Should -Be $ExpectedCalls
      }
      finally {
        $global:LASTEXITCODE = 0
      }
    }
  }
}
