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
  BeforeAll {
    $script:runbookPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'runbooks\Enable-AdvancedAuditing.ps1'
    $script:runbookHarness = @'
$ErrorActionPreference = 'Stop'
$ConfirmPreference = 'None'
$global:fixtureMailboxes = @(
  [pscustomobject]@{ PrimarySmtpAddress = 'private.one@example.invalid' }
  [pscustomobject]@{ PrimarySmtpAddress = 'private.two@example.invalid' }
)
$global:setMailboxInvocations = 0
$global:setMailboxExecutions = 0
$global:lookupCalls = 0
$global:disconnectCalls = 0
$runbookFailure = $null

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
    $global:lookupCalls++
    return $global:fixtureMailboxes[0]
  }
  return $global:fixtureMailboxes
}
function Set-Mailbox {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [string]$Identity,
    [bool]$AuditEnabled,
    [int]$AuditLogAgeLimit,
    [hashtable]$AuditAdmin,
    [hashtable]$AuditDelegate,
    [hashtable]$AuditOwner
  )
  $global:setMailboxInvocations++
  if ($PSCmdlet.ShouldProcess($Identity, 'Update mailbox auditing settings')) {
    $global:setMailboxExecutions++
    if ($env:AA_TEST_MODE -eq 'Failure') {
      throw 'fixture Set-Mailbox failure'
    }
    [pscustomobject]@{ ResultIdentity = $Identity; SyntheticResult = 'offline Exchange stub' }
  }
}
function Disconnect-ExchangeOnline {
  [CmdletBinding()]
  param([switch]$Confirm)
  $global:disconnectCalls++
}

switch ($env:AA_TEST_MODE) {
  'WhatIf' {
    & $env:AA_TEST_RUNBOOK -Organization 'fixture.example.invalid' -WhatIf
  }
  'Success' {
    & $env:AA_TEST_RUNBOOK -Organization 'fixture.example.invalid'
  }
  'Failure' {
    try {
      & $env:AA_TEST_RUNBOOK -Organization 'fixture.example.invalid'
    }
    catch {
      $runbookFailure = $_.Exception.Message
    }
    if ($runbookFailure -ne 'fixture Set-Mailbox failure') {
      throw 'The runbook did not propagate the setter failure.'
    }
  }
  default {
    throw "Unexpected runbook test mode: $env:AA_TEST_MODE"
  }
}

$summary = [pscustomobject]@{
  Mode = $env:AA_TEST_MODE
  SetMailboxInvocations = $global:setMailboxInvocations
  SetMailboxExecutions = $global:setMailboxExecutions
  LookupCalls = $global:lookupCalls
  DisconnectCalls = $global:disconnectCalls
  RunbookFailure = $runbookFailure
}
Write-Output ('FIXTURE_SUMMARY=' + ($summary | ConvertTo-Json -Compress))
'@

    function Invoke-RunbookHarness {
      param([Parameter(Mandatory)][ValidateSet('WhatIf', 'Success', 'Failure')][string]$Mode)

      $previousRunbookPath = $env:AA_TEST_RUNBOOK
      $previousMode = $env:AA_TEST_MODE
      try {
        $env:AA_TEST_RUNBOOK = $script:runbookPath
        $env:AA_TEST_MODE = $Mode
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:runbookHarness))
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -ErrorAction Stop).Source)
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-NoLogo', '-NoProfile', '-EncodedCommand', $encodedCommand)) {
          $startInfo.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
          $stdoutTask = $process.StandardOutput.ReadToEndAsync()
          $stderrTask = $process.StandardError.ReadToEndAsync()
          $process.WaitForExit()
          [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
          }
        }
        finally {
          $process.Dispose()
        }
      }
      finally {
        if ($null -eq $previousRunbookPath) { Remove-Item Env:AA_TEST_RUNBOOK -ErrorAction SilentlyContinue }
        else { $env:AA_TEST_RUNBOOK = $previousRunbookPath }
        if ($null -eq $previousMode) { Remove-Item Env:AA_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:AA_TEST_MODE = $previousMode }
      }
    }
  }

  It 'uses a count-only client WhatIf preview without leaking native ShouldProcess output' {
    $result = Invoke-RunbookHarness -Mode WhatIf
    $combinedOutput = $result.StdOut + [Environment]::NewLine + $result.StdErr
    $summaryLine = @($result.StdOut -split '\r?\n' | Where-Object { $_ -like 'FIXTURE_SUMMARY=*' } | Select-Object -Last 1)

    $result.ExitCode | Should -Be 0 -Because $combinedOutput
    $result.StdOut | Should -Match 'WhatIf preview identified 2 user mailboxes\.'
    $result.StdOut | Should -Match 'No Set-Mailbox calls were made; server-side update validation was not performed\.'
    $summaryLine.Count | Should -Be 1 -Because $combinedOutput
    $summary = ($summaryLine[0] -replace '^FIXTURE_SUMMARY=', '') | ConvertFrom-Json
    $summary.SetMailboxInvocations | Should -Be 0
    $summary.SetMailboxExecutions | Should -Be 0
    $summary.DisconnectCalls | Should -Be 1
    $combinedOutput | Should -Not -Match 'What if:|private\.(one|two)@example\.invalid|ResultIdentity|SyntheticResult'
  }

  It 'suppresses successful setter return objects in normal mode' {
    $result = Invoke-RunbookHarness -Mode Success
    $combinedOutput = $result.StdOut + [Environment]::NewLine + $result.StdErr
    $summaryLine = @($result.StdOut -split '\r?\n' | Where-Object { $_ -like 'FIXTURE_SUMMARY=*' } | Select-Object -Last 1)

    $result.ExitCode | Should -Be 0 -Because $combinedOutput
    $result.StdOut | Should -Match 'Completed auditing configuration for 2 user mailboxes\.'
    $summaryLine.Count | Should -Be 1 -Because $combinedOutput
    $summary = ($summaryLine[0] -replace '^FIXTURE_SUMMARY=', '') | ConvertFrom-Json
    $summary.SetMailboxInvocations | Should -Be 2
    $summary.SetMailboxExecutions | Should -Be 2
    $summary.DisconnectCalls | Should -Be 1
    $combinedOutput | Should -Not -Match 'private\.(one|two)@example\.invalid|ResultIdentity|SyntheticResult'
  }

  It 'preserves setter failures and disconnects in normal mode' {
    $result = Invoke-RunbookHarness -Mode Failure
    $combinedOutput = $result.StdOut + [Environment]::NewLine + $result.StdErr
    $summaryLine = @($result.StdOut -split '\r?\n' | Where-Object { $_ -like 'FIXTURE_SUMMARY=*' } | Select-Object -Last 1)

    $result.ExitCode | Should -Be 0 -Because $combinedOutput
    $summaryLine.Count | Should -Be 1 -Because $combinedOutput
    $summary = ($summaryLine[0] -replace '^FIXTURE_SUMMARY=', '') | ConvertFrom-Json
    $summary.SetMailboxInvocations | Should -Be 1
    $summary.SetMailboxExecutions | Should -Be 1
    $summary.DisconnectCalls | Should -Be 1
    $summary.RunbookFailure | Should -BeExactly 'fixture Set-Mailbox failure'
    $combinedOutput | Should -Not -Match 'private\.(one|two)@example\.invalid'
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
