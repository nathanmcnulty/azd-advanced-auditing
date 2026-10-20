#Requires -Version 7.6
[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$Organization = '',

  [Parameter(Mandatory = $false)]
  [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-AuditRetentionSetupSignal {
  param([AllowNull()][string]$RawState, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
  $status='unknown'
  $observedAt=$null
  $accountId=$null
  try {
    if ([string]::IsNullOrWhiteSpace($RawState) -or $RawState.Length -gt 2048) { throw 'Invalid state' }
    $state=$RawState | ConvertFrom-Json -DateKind String -ErrorAction Stop
    if (@($state.PSObject.Properties.Name | Where-Object { $_ -notin @('kind','schemaVersion','accountId','observedAt','setupState') }).Count -or
      $state.kind -cne 'advancedAuditing.retentionSetup' -or $state.schemaVersion -cne '1.0' -or
      $state.accountId -notmatch '^/subscriptions/[a-f0-9-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft.Automation/automationAccounts/[A-Za-z0-9_-]+$' -or
      $state.setupState -cnotin @('setupVerified','setupUnavailable','setupFailed') -or $state.observedAt -isnot [string]) { throw 'Invalid state' }
    $stamp=[DateTimeOffset]::Parse($state.observedAt,[Globalization.CultureInfo]::InvariantCulture)
    if ($stamp -gt $Now.AddMinutes(5)) { throw 'Invalid state' }
    $observedAt=$stamp.ToUniversalTime().ToString('o')
    $accountId=[string]$state.accountId
    $status=if($stamp -lt $Now.AddDays(-7)){'stale'}elseif($state.setupState -eq 'setupVerified'){'bootstrapVerified'}else{'degraded'}
  } catch { $status='unknown'; $observedAt=$null; $accountId=$null }
  # Retain validated resource provenance. The diagnostic query binds it to
  # the trusted emitting _ResourceId before treating any bootstrap status as usable.
  [ordered]@{kind='advancedAuditing.retentionSetup';schemaVersion='1.0';accountId=$accountId;status=$status;observedAt=$observedAt;recordedAt=$Now.ToUniversalTime().ToString('o');evidenceScope='bootstrapOnly'} | ConvertTo-Json -Compress
}

function Get-ExchangeOrganization {
  param([Parameter(Mandatory = $false)][AllowEmptyString()][string]$ConfiguredValue)

  if (-not [string]::IsNullOrWhiteSpace($ConfiguredValue)) {
    return $ConfiguredValue.Trim()
  }

  try {
    $automationValue = Get-AutomationVariable -Name 'ExchangeOrganization' -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace([string]$automationValue)) {
      return [string]$automationValue
    }
  }
  catch {
    Write-Verbose "Could not read Automation variable ExchangeOrganization: $($_.Exception.Message)"
  }

  throw "Exchange organization was not provided and Automation variable 'ExchangeOrganization' is empty."
}

$exchangeOrganization = Get-ExchangeOrganization -ConfiguredValue $Organization
# A bounded bootstrap observation is operational evidence, never a current
# Purview retention check. Missing/old state stays unknown/stale respectively.
$retentionSetupState=$null
try { $retentionSetupState=[string](Get-AutomationVariable -Name 'AuditRetentionSetupState' -ErrorAction Stop) } catch { }
Write-Output (ConvertTo-AuditRetentionSetupSignal -RawState $retentionSetupState)
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

$auditAdminActions = @(
  'Update', 'Copy', 'Move', 'MoveToDeletedItems', 'SoftDelete', 'HardDelete', 'FolderBind',
  'SendAs', 'SendOnBehalf', 'MessageBind', 'Create', 'UpdateFolderPermissions',
  'AddFolderPermissions', 'ModifyFolderPermissions', 'RemoveFolderPermissions',
  'UpdateInboxRules', 'UpdateCalendarDelegation', 'RecordDelete', 'ApplyRecord',
  'MailItemsAccessed', 'UpdateComplianceTag', 'Send', 'AttachmentAccess',
  'PriorityCleanupDelete', 'ApplyPriorityCleanup', 'PreservedMailItemProactively'
)

$auditDelegateActions = @(
  'Update', 'Move', 'MoveToDeletedItems', 'SoftDelete', 'HardDelete', 'FolderBind',
  'SendAs', 'SendOnBehalf', 'Create', 'UpdateFolderPermissions', 'AddFolderPermissions',
  'ModifyFolderPermissions', 'RemoveFolderPermissions', 'UpdateInboxRules', 'RecordDelete',
  'ApplyRecord', 'MailItemsAccessed', 'UpdateComplianceTag', 'AttachmentAccess',
  'PriorityCleanupDelete', 'ApplyPriorityCleanup', 'PreservedMailItemProactively'
)

$auditOwnerActions = @(
  'Update', 'Move', 'MoveToDeletedItems', 'SoftDelete', 'HardDelete', 'Create', 'MailboxLogin',
  'UpdateFolderPermissions', 'AddFolderPermissions', 'ModifyFolderPermissions',
  'RemoveFolderPermissions', 'UpdateInboxRules', 'UpdateCalendarDelegation', 'RecordDelete',
  'ApplyRecord', 'MailItemsAccessed', 'UpdateComplianceTag', 'Send', 'SearchQueryInitiated',
  'AttachmentAccess', 'PriorityCleanupDelete', 'ApplyPriorityCleanup',
  'PreservedMailItemProactively'
)

try {
  Connect-ExchangeOnline -ManagedIdentity -Organization $exchangeOrganization -ShowBanner:$false | Out-Null

  $mailboxes = @(Get-Mailbox -ResultSize Unlimited -Filter { RecipientType -eq "UserMailbox" -and RecipientTypeDetails -ne "DiscoveryMailbox" })
  Write-Output "Processing $($mailboxes.Count) user mailboxes."

  if ($mailboxes.Count -gt 0) {
    Get-Mailbox -Identity $mailboxes[0].PrimarySmtpAddress.ToString() | Out-Null
  }

  foreach ($mailbox in $mailboxes) {
    $identity = $mailbox.PrimarySmtpAddress.ToString()
    Write-Output "Updating $identity"

    $setMailboxParams = @{
      Identity        = $identity
      AuditEnabled    = $true
      AuditLogAgeLimit = 365
      AuditAdmin      = @{ add = $auditAdminActions }
      AuditDelegate   = @{ add = $auditDelegateActions }
      AuditOwner      = @{ add = $auditOwnerActions }
    }

    if ($WhatIf.IsPresent) {
      $setMailboxParams['WhatIf'] = $true
    }

    Set-Mailbox @setMailboxParams
  }
}
finally {
  Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
