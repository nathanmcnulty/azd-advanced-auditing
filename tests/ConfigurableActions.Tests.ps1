#Requires -Version 7.6
BeforeAll {
  $script:actionRepoRoot = Split-Path $PSScriptRoot -Parent
  function Invoke-ActionRunbookFixture {
    param([switch]$Validate, [switch]$WhatIf, [switch]$MissingUpdate)
    $state = @{ setters=@(); queries=@(); connects=0; disconnects=0; error=$null }
    function Get-Module {
      param($Name,[switch]$ListAvailable)
      [pscustomobject]@{Path='offline-eom-fixture';Version=[version]'3.10.1'}
    }
    function Import-Module { param($Name,[switch]$Force) }
    function Connect-ExchangeOnline { param([switch]$ManagedIdentity,$Organization,$ShowBanner) $state.connects++ }
    function Disconnect-ExchangeOnline { param($Confirm,$ErrorAction) $state.disconnects++ }
    function Get-MailboxAuditBypassAssociation { param($ResultSize) }
    function Get-Mailbox {
      param($Identity,$ResultSize,$Filter)
      $state.queries += @{identity=$Identity;resultSize=$ResultSize;filter=[string]$Filter}
      # Full configurable sets; deliberately no AttachmentAccess property value.
      $all = @('Update','Copy','Move','MoveToDeletedItems','SoftDelete','HardDelete','FolderBind',
        'SendAs','SendOnBehalf','MessageBind','Create','UpdateFolderPermissions',
        'AddFolderPermissions','ModifyFolderPermissions','RemoveFolderPermissions','UpdateInboxRules',
        'UpdateCalendarDelegation','RecordDelete','ApplyRecord','MailItemsAccessed','UpdateComplianceTag',
        'Send','PriorityCleanupDelete','ApplyPriorityCleanup','PreservedMailItemProactively',
        'MailboxLogin','SearchQueryInitiated')
      if ($MissingUpdate) { $all = @($all | Where-Object { $_ -ne 'Update' }) }
      foreach ($address in @('first@example.com','second@example.com')) {
        [pscustomobject]@{PrimarySmtpAddress=$address;AuditEnabled=$true;AuditLogAgeLimit=[timespan]::FromDays(365);AuditAdmin=$all;AuditDelegate=$all;AuditOwner=$all}
      }
    }
    function Set-Mailbox {
      param($Identity,$AuditEnabled,$AuditLogAgeLimit,$AuditAdmin,$AuditDelegate,$AuditOwner,[switch]$WhatIf)
      foreach ($actions in @($AuditAdmin,$AuditDelegate,$AuditOwner)) {
        if ($actions.add -contains 'AttachmentAccess') { throw 'Service fixture rejects non-configurable AttachmentAccess.' }
      }
      $state.setters += @{identity=$Identity;whatIf=[bool]$WhatIf;enabled=$AuditEnabled;age=$AuditLogAgeLimit;admin=$AuditAdmin;delegate=$AuditDelegate;owner=$AuditOwner}
    }
    try {
      if ($Validate) { & (Join-Path $script:actionRepoRoot 'runbooks/Validate-AdvancedAuditingConfiguration.ps1') -Organization 'fixture.onmicrosoft.com' | Out-Null }
      else { & (Join-Path $script:actionRepoRoot 'runbooks/Enable-AdvancedAuditing.ps1') -Organization 'fixture.onmicrosoft.com' -WhatIf:$WhatIf | Out-Null }
    } catch { $state.error=$_.Exception.Message }
    return $state
  }
}
Describe 'Configurable mailbox audit actions' {
  It 'remediates every returned mailbox without passing non-configurable AttachmentAccess' {
    $result=Invoke-ActionRunbookFixture
    $result.error | Should -BeNullOrEmpty
    $result.setters.Count | Should -Be 2
    @($result.setters.identity) | Should -Be @('first@example.com','second@example.com')
    foreach ($setter in $result.setters) {
      $setter.enabled | Should -BeTrue
      $setter.age | Should -Be 365
      foreach ($role in @('admin','delegate','owner')) { $setter[$role].add | Should -Contain 'Update' }
    }
    @($result.queries | Where-Object { $_.resultSize -eq 'Unlimited' }).Count | Should -Be 1
    $result.queries[0].filter | Should -Match 'RecipientType -eq "UserMailbox" -and RecipientTypeDetails -ne "DiscoveryMailbox"'
    $result.disconnects | Should -Be 1
  }
  It 'preserves WhatIf for every returned mailbox' {
    $result=Invoke-ActionRunbookFixture -WhatIf
    $result.error | Should -BeNullOrEmpty
    $result.setters.Count | Should -Be 2
    @($result.setters | Where-Object { -not $_.whatIf }).Count | Should -Be 0
  }
  It 'accepts configured audit lists without requiring AttachmentAccess to be returned' {
    $result=Invoke-ActionRunbookFixture -Validate
    $result.error | Should -BeNullOrEmpty
    $result.setters.Count | Should -Be 0
    $result.disconnects | Should -Be 1
  }
  It 'still rejects a missing configurable action' {
    $result=Invoke-ActionRunbookFixture -Validate -MissingUpdate
    $result.error | Should -Match 'missing expected AuditAdmin entries'
    $result.setters.Count | Should -Be 0
    $result.disconnects | Should -Be 1
  }
}
