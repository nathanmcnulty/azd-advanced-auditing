[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$Organization = '',

  [Parameter(Mandatory = $false)]
  [int]$SampleSize = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ExchangeOrganization {
  param([Parameter(Mandatory = $false)][AllowEmptyString()][string]$ConfiguredValue)

  if (-not [string]::IsNullOrWhiteSpace($ConfiguredValue)) {
    return $ConfiguredValue.Trim()
  }

  $automationValue = Get-AutomationVariable -Name 'ExchangeOrganization'
  if (-not [string]::IsNullOrWhiteSpace([string]$automationValue)) {
    return [string]$automationValue
  }

  throw "Exchange organization was not provided and Automation variable 'ExchangeOrganization' is empty."
}

function Test-ContainsAll {
  param(
    [Parameter(Mandatory = $true)][object[]]$CurrentValues,
    [Parameter(Mandatory = $true)][string[]]$ExpectedValues
  )

  foreach ($expectedValue in $ExpectedValues) {
    if ($CurrentValues -notcontains $expectedValue) {
      return $false
    }
  }

  return $true
}

$exchangeOrganization = Get-ExchangeOrganization -ConfiguredValue $Organization
$minimumExchangeOnlineManagementVersion = [version]'3.10.1'
$exchangeOnlineManagementModule = Get-Module -ListAvailable -Name 'ExchangeOnlineManagement' |
  Where-Object { $_.Version -ge $minimumExchangeOnlineManagementVersion } |
  Sort-Object Version -Descending |
  Select-Object -First 1

if (-not $exchangeOnlineManagementModule) {
  throw "ExchangeOnlineManagement version $minimumExchangeOnlineManagementVersion or newer is not available in the Automation runtime."
}

Import-Module -Name $exchangeOnlineManagementModule.Path -Force
Write-Output "Using ExchangeOnlineManagement $($exchangeOnlineManagementModule.Version)."

$expectedAdmin = @('MailItemsAccessed', 'Send')
$expectedDelegate = @('MailItemsAccessed')
$expectedOwner = @('MailItemsAccessed', 'Send', 'SearchQueryInitiated')

try {
  Connect-ExchangeOnline -ManagedIdentity -Organization $exchangeOrganization -ShowBanner:$false | Out-Null

  $mailboxes = @(Get-Mailbox -ResultSize $SampleSize -Filter { RecipientType -eq "UserMailbox" -and RecipientTypeDetails -ne "DiscoveryMailbox" })
  if ($mailboxes.Count -eq 0) {
    throw 'No user mailboxes were returned during validation.'
  }

  $failures = [System.Collections.Generic.List[string]]::new()

  foreach ($mailbox in $mailboxes) {
    if (-not (Test-ContainsAll -CurrentValues @($mailbox.AuditAdmin) -ExpectedValues $expectedAdmin)) {
      $failures.Add("$($mailbox.PrimarySmtpAddress): missing expected AuditAdmin entries")
    }

    if (-not (Test-ContainsAll -CurrentValues @($mailbox.AuditDelegate) -ExpectedValues $expectedDelegate)) {
      $failures.Add("$($mailbox.PrimarySmtpAddress): missing expected AuditDelegate entries")
    }

    if (-not (Test-ContainsAll -CurrentValues @($mailbox.AuditOwner) -ExpectedValues $expectedOwner)) {
      $failures.Add("$($mailbox.PrimarySmtpAddress): missing expected AuditOwner entries")
    }
  }

  if ($failures.Count -gt 0) {
    throw ($failures -join [Environment]::NewLine)
  }

  Write-Output "Validated advanced auditing settings on $($mailboxes.Count) user mailboxes."
}
finally {
  Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
