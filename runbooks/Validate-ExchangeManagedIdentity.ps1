[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$Organization = ''
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

$exchangeOrganization = Get-ExchangeOrganization -ConfiguredValue $Organization

try {
  Connect-ExchangeOnline -ManagedIdentity -Organization $exchangeOrganization -ShowBanner:$false | Out-Null
  $mailbox = Get-Mailbox -ResultSize 1 -Filter { RecipientType -eq "UserMailbox" -and RecipientTypeDetails -ne "DiscoveryMailbox" }
  if (-not $mailbox) {
    throw 'No user mailboxes were returned during validation.'
  }

  Write-Output "Managed identity connection succeeded. Sample mailbox: $($mailbox.PrimarySmtpAddress)"
}
finally {
  Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
