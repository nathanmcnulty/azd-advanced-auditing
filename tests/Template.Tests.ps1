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
