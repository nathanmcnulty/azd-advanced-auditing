#Requires -Version 7.6
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Import-Module Pester -RequiredVersion 6.2.0 -Force -ErrorAction Stop
$pester = @(Get-Module Pester)
if ($pester.Count -ne 1 -or $pester[0].Version -ne [version]'6.2.0') {
  throw 'Repository validation requires exactly Pester 6.2.0 to be selected.'
}
Write-Host "PowerShell $($PSVersionTable.PSVersion); Pester $($pester[0].Version)"
Invoke-Pester -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'tests') -CI
