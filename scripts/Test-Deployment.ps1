#Requires -Version 7.6
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TargetPath,[switch]$Plan)
$ErrorActionPreference='Stop'
try{$target=Get-Content -LiteralPath $TargetPath -Raw -ErrorAction Stop|ConvertFrom-Json -DateKind String -Depth 32}catch{throw 'Validation target could not be read as JSON; contents withheld.'}
Import-Module "$PSScriptRoot/Audit.Validation.psm1" -Force
$report=Invoke-AuditDeploymentValidation -Target $target -Plan:$Plan
$report|ConvertTo-Json -Depth 64
if(@($report.checks|Where-Object status -eq 'fail').Count){exit 1}
