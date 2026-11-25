#Requires -Version 7.6
BeforeAll {
  $root = Split-Path $PSScriptRoot
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile("$root/hooks/postprovision.ps1", [ref]$tokens, [ref]$errors)
  if ($errors) { throw ($errors | Out-String) }
  $names = 'Assert-AuditNativeContext', 'Ensure-MailboxAuditingRole'
  $definitions = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names
  }, $true)
  if ($definitions.Count -ne 2) { throw 'Expected native write guard and role helper.' }
  . ([scriptblock]::Create(($definitions.Extent.Text -join "`n")))
  function Assert-AuditHookContext { param($Context) if ($Context -ne 'verified') { throw 'Unexpected Azure context.' } }
  function Get-AzCliUserPrincipalName { 'operator@example.test' }
  function New-AuditOperatorContextException { param([string]$Message) [InvalidOperationException]::new($Message) }
  function Get-ConnectionInformation { param($ErrorAction) $script:connection }
  function Get-Command { param($Name, $ErrorAction) @{CommandType = 'Function'; ModuleName = $script:commandModule} }
  function Get-ManagementRole { @{Name = 'Mailbox Auditing'} }
  function Get-ManagementRoleEntry { @{Name = 'Set-Mailbox'} }
  function Remove-ManagementRoleEntry {
    param($Identity, $Confirm)
    $script:nativeWrites.Add('remove')
    $script:connection.UserPrincipalName = 'other@example.test'
  }
  function Add-ManagementRoleEntry { $script:nativeWrites.Add('add') }
}

Describe 'Exchange and Compliance native hook dispatch' {
  BeforeEach {
    $script:AuditHookContext = 'verified'
    $script:AuditOperatorTenantId = '22222222-2222-2222-2222-222222222222'
    $script:commandModule = 'verified-exchange'
    $script:connection = [pscustomobject]@{
      IsEopSession = $false; TenantID = $script:AuditOperatorTenantId; UserPrincipalName = 'operator@example.test'
      State = 'Connected'; TokenStatus = 'Active'; CertificateAuthentication = $false; ModulePrefix = ''; DelegatedOrganization = ''
      ModuleName = 'verified-exchange'; ConnectionUri = 'https://outlook.office365.com/powershell-liveid/'
      TokenExpiryTimeUTC = [datetimeoffset]::UtcNow.AddHours(1)
    }
    $script:nativeWrites = [Collections.Generic.List[string]]::new()
  }

  It 'accepts the exact active native Exchange connection and dispatching module' {
    { Assert-AuditNativeContext -Service Exchange -CommandName 'Set-AdminAuditLogConfig' } | Should -Not -Throw
  }

  It 'rejects <Property> before a native mutation' -ForEach @(
    @{Property = 'TenantID'; ChangedValue = '33333333-3333-3333-3333-333333333333'}
    @{Property = 'UserPrincipalName'; ChangedValue = 'other@example.test'}
    @{Property = 'TokenStatus'; ChangedValue = 'Expired'}
    @{Property = 'ConnectionUri'; ChangedValue = 'https://outlook.office365.com.example.test/'}
  ) {
    $script:connection.$Property = $ChangedValue
    { Ensure-MailboxAuditingRole } | Should -Throw '*could not be verified before mutation*'
    $script:nativeWrites.Count | Should -Be 0
  }

  It 'rejects a cmdlet dispatched by a different connected module' {
    $script:commandModule = 'other-module'
    { Ensure-MailboxAuditingRole } | Should -Throw '*could not be verified before mutation*'
    $script:nativeWrites.Count | Should -Be 0
  }

  It 'stops before adding the role entry when the native actor changes after removal' {
    { Ensure-MailboxAuditingRole } | Should -Throw '*could not be verified before mutation*'
    $script:nativeWrites | Should -Be @('remove')
  }

  It 'accepts the active Compliance endpoint for retention and rejects an Exchange endpoint' {
    $script:connection.IsEopSession = $true
    $script:connection.ConnectionUri = 'https://ps.compliance.protection.outlook.com/powershell-liveid/'
    { Assert-AuditNativeContext -Service Compliance -CommandName 'New-UnifiedAuditLogRetentionPolicy' } | Should -Not -Throw
    $script:connection.ConnectionUri = 'https://outlook.office365.com/powershell-liveid/'
    { Assert-AuditNativeContext -Service Compliance -CommandName 'New-UnifiedAuditLogRetentionPolicy' } | Should -Throw
  }
}
