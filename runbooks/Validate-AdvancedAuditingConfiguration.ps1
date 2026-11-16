[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$Organization = '',

  [Parameter(Mandatory = $false)]
  [ValidateRange(0, 1000000)]
  [int]$SampleSize = 0
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
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$CurrentValues,
    [Parameter(Mandatory = $true)][string[]]$ExpectedValues
  )

  foreach ($expectedValue in $ExpectedValues) {
    if ($CurrentValues -notcontains $expectedValue) {
      return $false
    }
  }

  return $true
}

function Get-AdvancedAuditingFailureSummary {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Mailboxes,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$BypassAssociations,
    [Parameter(Mandatory = $true)][string[]]$ExpectedAdmin,
    [Parameter(Mandatory = $true)][string[]]$ExpectedDelegate,
    [Parameter(Mandatory = $true)][string[]]$ExpectedOwner
  )

  $failureCounts = [ordered]@{
    MailboxAuditBypassEnabled = $BypassAssociations.Count
    AuditEnabledFalse = 0
    AuditLogAgeLimitBelow365Days = 0
    MissingExpectedAuditAdminEntries = 0
    MissingExpectedAuditDelegateEntries = 0
    MissingExpectedAuditOwnerEntries = 0
  }

  foreach ($mailbox in $Mailboxes) {
    if (-not [bool]$mailbox.AuditEnabled) {
      $failureCounts.AuditEnabledFalse++
    }

    $auditLogAgeLimit = [timespan]$mailbox.AuditLogAgeLimit
    if ($auditLogAgeLimit.TotalDays -lt 365) {
      $failureCounts.AuditLogAgeLimitBelow365Days++
    }

    if (-not (Test-ContainsAll -CurrentValues @($mailbox.AuditAdmin) -ExpectedValues $ExpectedAdmin)) {
      $failureCounts.MissingExpectedAuditAdminEntries++
    }

    if (-not (Test-ContainsAll -CurrentValues @($mailbox.AuditDelegate) -ExpectedValues $ExpectedDelegate)) {
      $failureCounts.MissingExpectedAuditDelegateEntries++
    }

    if (-not (Test-ContainsAll -CurrentValues @($mailbox.AuditOwner) -ExpectedValues $ExpectedOwner)) {
      $failureCounts.MissingExpectedAuditOwnerEntries++
    }
  }

  $failureSummary = [System.Collections.Generic.List[string]]::new()
  if ($failureCounts.MailboxAuditBypassEnabled -gt 0) {
    $failureSummary.Add("Mailbox audit bypass enabled for $($failureCounts.MailboxAuditBypassEnabled) association(s)")
  }
  if ($failureCounts.AuditEnabledFalse -gt 0) {
    $failureSummary.Add("AuditEnabled=false for $($failureCounts.AuditEnabledFalse) user mailbox(es)")
  }
  if ($failureCounts.AuditLogAgeLimitBelow365Days -gt 0) {
    $failureSummary.Add("AuditLogAgeLimit below 365 days for $($failureCounts.AuditLogAgeLimitBelow365Days) user mailbox(es)")
  }
  if ($failureCounts.MissingExpectedAuditAdminEntries -gt 0) {
    $failureSummary.Add("Missing expected AuditAdmin entries for $($failureCounts.MissingExpectedAuditAdminEntries) user mailbox(es)")
  }
  if ($failureCounts.MissingExpectedAuditDelegateEntries -gt 0) {
    $failureSummary.Add("Missing expected AuditDelegate entries for $($failureCounts.MissingExpectedAuditDelegateEntries) user mailbox(es)")
  }
  if ($failureCounts.MissingExpectedAuditOwnerEntries -gt 0) {
    $failureSummary.Add("Missing expected AuditOwner entries for $($failureCounts.MissingExpectedAuditOwnerEntries) user mailbox(es)")
  }

  return $failureSummary.ToArray()
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

$expectedAdmin = @(
  'Update', 'Copy', 'Move', 'MoveToDeletedItems', 'SoftDelete', 'HardDelete', 'FolderBind',
  'SendAs', 'SendOnBehalf', 'MessageBind', 'Create', 'UpdateFolderPermissions',
  'AddFolderPermissions', 'ModifyFolderPermissions', 'RemoveFolderPermissions',
  'UpdateInboxRules', 'UpdateCalendarDelegation', 'RecordDelete', 'ApplyRecord',
  'MailItemsAccessed', 'UpdateComplianceTag', 'Send', 'AttachmentAccess',
  'PriorityCleanupDelete', 'ApplyPriorityCleanup', 'PreservedMailItemProactively'
)

$expectedDelegate = @(
  'Update', 'Move', 'MoveToDeletedItems', 'SoftDelete', 'HardDelete', 'FolderBind',
  'SendAs', 'SendOnBehalf', 'Create', 'UpdateFolderPermissions', 'AddFolderPermissions',
  'ModifyFolderPermissions', 'RemoveFolderPermissions', 'UpdateInboxRules', 'RecordDelete',
  'ApplyRecord', 'MailItemsAccessed', 'UpdateComplianceTag', 'AttachmentAccess',
  'PriorityCleanupDelete', 'ApplyPriorityCleanup', 'PreservedMailItemProactively'
)

$expectedOwner = @(
  'Update', 'Move', 'MoveToDeletedItems', 'SoftDelete', 'HardDelete', 'Create', 'MailboxLogin',
  'UpdateFolderPermissions', 'AddFolderPermissions', 'ModifyFolderPermissions',
  'RemoveFolderPermissions', 'UpdateInboxRules', 'UpdateCalendarDelegation', 'RecordDelete',
  'ApplyRecord', 'MailItemsAccessed', 'UpdateComplianceTag', 'Send', 'SearchQueryInitiated',
  'AttachmentAccess', 'PriorityCleanupDelete', 'ApplyPriorityCleanup',
  'PreservedMailItemProactively'
)

try {
  Connect-ExchangeOnline -ManagedIdentity -Organization $exchangeOrganization -ShowBanner:$false | Out-Null

  $resultSize = if ($SampleSize -eq 0) { 'Unlimited' } else { $SampleSize }
  $mailboxes = @(Get-Mailbox -ResultSize $resultSize -Filter { RecipientType -eq "UserMailbox" -and RecipientTypeDetails -ne "DiscoveryMailbox" })
  if ($mailboxes.Count -eq 0) {
    throw 'No user mailboxes were returned during validation.'
  }

  $bypassAssociations = @(Get-MailboxAuditBypassAssociation -ResultSize Unlimited | Where-Object { $_.AuditBypassEnabled -eq $true })
  $failureSummary = @(Get-AdvancedAuditingFailureSummary -Mailboxes $mailboxes -BypassAssociations $bypassAssociations `
    -ExpectedAdmin $expectedAdmin -ExpectedDelegate $expectedDelegate -ExpectedOwner $expectedOwner)

  if ($failureSummary.Count -gt 0) {
    throw "Advanced auditing validation failed for $($mailboxes.Count) user mailbox(es): $($failureSummary -join '; ')."
  }

  Write-Output "Validated complete advanced auditing settings on $($mailboxes.Count) user mailboxes; no audit bypass associations were enabled."
}
finally {
  Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
