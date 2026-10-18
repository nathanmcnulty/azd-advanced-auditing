#requires -Version 7.6

BeforeAll {
  $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks/postprovision.ps1'
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw ($errors | Out-String) }
  $definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Connect-ComplianceForBootstrap'
  }, $true)
  $decision = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -eq '$complianceConnected'
  }, $true))
  if ($null -eq $definition -or $decision.Count -ne 1) { throw 'Expected the maintained connection function and retention decision.' }
  $script:connectionDefinition = [scriptblock]::Create($definition.Extent.Text)
  $script:retentionDecision = [scriptblock]::Create($decision[0].Extent.Text)

  function Invoke-OfflineComplianceBootstrap {
    param([switch]$FailUpn, [switch]$FailOrganization, [switch]$FailToken)
    & {
      param([bool]$FailUpn, [bool]$FailOrganization, [bool]$FailToken)
      $WarningPreference = 'SilentlyContinue'
      . $script:connectionDefinition
      $calls = [Collections.Generic.List[object]]::new()
      $retentionCalls = [Collections.Generic.List[string]]::new()
      function Get-AzCliUserPrincipalName { 'operator@example.test' }
      function Get-AzCliAccessToken {
        param($ResourceUrl)
        if ($ResourceUrl -ne 'https://ps.compliance.protection.outlook.com') { throw 'Unexpected token audience.' }
        if ($FailToken) { throw 'Offline token unavailable.' }
        'offline-token'
      }
      function Connect-IPPSSession {
        param($AccessToken, $UserPrincipalName, $Organization, [bool]$ShowBanner)
        $calls.Add(@{} + $PSBoundParameters)
        if (($UserPrincipalName -and $FailUpn) -or ($Organization -and $FailOrganization)) { throw 'Offline connection failure.' }
        [pscustomobject]@{ UnexpectedOutput = 'must not escape the connection helper' }
      }
      function Ensure-AuditRetentionPolicy { param($PolicyName) $retentionCalls.Add($PolicyName) }
      $retentionPolicyName = 'All Records - 1 Year'
      $degradedConditions = [Collections.Generic.List[string]]::new()
      $complianceConnected = Connect-ComplianceForBootstrap -Organization 'example.onmicrosoft.com'
      & $script:retentionDecision
      [pscustomobject]@{
        Connected = $complianceConnected; ConnectionCalls = $calls.ToArray()
        RetentionCalls = $retentionCalls.ToArray(); DegradedCount = $degradedConditions.Count
      }
    } $FailUpn.IsPresent $FailOrganization.IsPresent $FailToken.IsPresent
  }
}

Describe 'Compliance bootstrap connection result and retention decision' {
  It 'runs retention setup once after primary UPN authentication succeeds' {
    $result = Invoke-OfflineComplianceBootstrap
    $result.Connected | Should -BeOfType ([bool])
    $result.Connected | Should -BeTrue
    $result.ConnectionCalls.Count | Should -Be 1
    $result.ConnectionCalls[0].UserPrincipalName | Should -Be 'operator@example.test'
    $result.ConnectionCalls[0].ContainsKey('Organization') | Should -BeFalse
    $result.RetentionCalls | Should -Be @('All Records - 1 Year')
    $result.DegradedCount | Should -Be 0
  }

  It 'runs retention setup once after the existing organization fallback succeeds' {
    $result = Invoke-OfflineComplianceBootstrap -FailUpn
    $result.Connected | Should -BeOfType ([bool])
    $result.Connected | Should -BeTrue
    $result.ConnectionCalls.Count | Should -Be 2
    $result.ConnectionCalls[1].Organization | Should -Be 'example.onmicrosoft.com'
    $result.RetentionCalls | Should -Be @('All Records - 1 Year')
    $result.DegradedCount | Should -Be 0
  }

  It 'preserves the degraded outcome and skips retention when both connections fail' {
    $result = Invoke-OfflineComplianceBootstrap -FailUpn -FailOrganization
    $result.Connected | Should -BeOfType ([bool])
    $result.Connected | Should -BeFalse
    $result.ConnectionCalls.Count | Should -Be 2
    $result.RetentionCalls.Count | Should -Be 0
    $result.DegradedCount | Should -Be 1
  }

  It 'preserves the fatal token acquisition failure' {
    { Invoke-OfflineComplianceBootstrap -FailToken } | Should -Throw '*Offline token unavailable*'
  }
}
