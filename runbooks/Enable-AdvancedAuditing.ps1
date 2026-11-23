<#
.SYNOPSIS
Configures advanced mailbox auditing.

.DESCRIPTION
The -WhatIf option performs a client-side inventory preview and reports only
the matching mailbox count. It does not call Set-Mailbox or validate whether
Exchange will accept the server-side updates.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$Organization = '',

  [Parameter(Mandatory = $false)]
  [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

  if ($WhatIf.IsPresent) {
    Write-Output "WhatIf preview identified $($mailboxes.Count) user mailboxes. No Set-Mailbox calls were made; server-side update validation was not performed."
  }
  else {
    Write-Output "Processing $($mailboxes.Count) user mailboxes."

    if ($mailboxes.Count -gt 0) {
      Get-Mailbox -Identity $mailboxes[0].PrimarySmtpAddress.ToString() | Out-Null
    }

    foreach ($mailbox in $mailboxes) {
      $identity = $mailbox.PrimarySmtpAddress.ToString()

      $setMailboxParams = @{
        Identity        = $identity
        AuditEnabled    = $true
        AuditLogAgeLimit = 365
        AuditAdmin      = @{ add = $auditAdminActions }
        AuditDelegate   = @{ add = $auditDelegateActions }
        AuditOwner      = @{ add = $auditOwnerActions }
      }

      Set-Mailbox @setMailboxParams | Out-Null
    }

    Write-Output "Completed auditing configuration for $($mailboxes.Count) user mailboxes."
  }
}
finally {
  Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
