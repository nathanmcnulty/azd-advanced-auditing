#Requires -Version 7.6
BeforeAll {
  $script:repoRoot = Split-Path $PSScriptRoot -Parent
  $script:runnerPath = Join-Path $script:repoRoot 'scripts/Test-Repository.ps1'
}

Describe 'Supported authoring and runtime baseline' {
  It 'requires PowerShell 7.6 at every maintained script entrypoint' {
    $ownedFiles = @(foreach ($directory in @('hooks', 'runbooks', 'scripts', 'tests')) {
      Get-ChildItem (Join-Path $script:repoRoot $directory) -File |
        Where-Object Extension -in '.ps1', '.psm1'
    })
    $ownedFiles.Count | Should -BeGreaterThan 20
    foreach ($file in $ownedFiles) {
      $tokens = $null
      $parseErrors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
      $parseErrors | Should -BeNullOrEmpty
      $ast.ScriptRequirements.RequiredPSVersion | Should -Be ([version]'7.6') -Because $file.Name
    }
  }

  It 'runs the actual full-suite entrypoint with the selected pinned Pester' {
    & {
      $state = @{ Calls = 0; Imported = $null; Path = $null; CI = $false }
      function Import-Module { param($Name, $RequiredVersion, [switch]$Force, $ErrorAction) $state.Imported = "$Name/$RequiredVersion/$Force" }
      function Get-Module { param($Name) [pscustomobject]@{ Name = $Name; Version = [version]'6.2.0' } }
      function Invoke-Pester { param($Path, [switch]$CI) $state.Calls++; $state.Path = $Path; $state.CI = $CI }
      & $script:runnerPath
      $state.Imported | Should -Be 'Pester/6.2.0/True'
      $state.Calls | Should -Be 1
      $state.Path | Should -Be (Join-Path $script:repoRoot 'tests')
      $state.CI | Should -BeTrue
    }
  }

  It 'stops before tests when the selected Pester is <Case>' -ForEach @(
    @{ Case = 'missing'; Selected = $null },
    @{ Case = 'older'; Selected = [version]'6.1.0' },
    @{ Case = 'unreviewed'; Selected = [version]'6.3.0' }
  ) {
    & {
      $state = @{ Calls = 0 }
      function Import-Module { param($Name, $RequiredVersion, [switch]$Force, $ErrorAction) }
      function Get-Module { param($Name) if ($null -ne $Selected) { [pscustomobject]@{ Name = $Name; Version = $Selected } } }
      function Invoke-Pester { param($Path, [switch]$CI) $state.Calls++ }
      { & $script:runnerPath } | Should -Throw '*Pester 6.2.0*'
      $state.Calls | Should -Be 0
    }
  }

  It 'stops before tests when the exact Pester import fails' {
    & {
      $state = @{ Calls = 0 }
      function Import-Module { param($Name, $RequiredVersion, [switch]$Force, $ErrorAction) throw 'Fixture import failure.' }
      function Invoke-Pester { param($Path, [switch]$CI) $state.Calls++ }
      { & $script:runnerPath } | Should -Throw 'Fixture import failure.'
      $state.Calls | Should -Be 0
    }
  }

  It 'uses the same test entrypoint in CI and contributor guidance' {
    Get-Content (Join-Path $script:repoRoot '.github/workflows/validate.yml') -Raw |
      Should -Match '\./scripts/Test-Repository\.ps1'
    Get-Content (Join-Path $script:repoRoot 'docs/development.md') -Raw |
      Should -Match '\./scripts/Test-Repository\.ps1'
  }
}
