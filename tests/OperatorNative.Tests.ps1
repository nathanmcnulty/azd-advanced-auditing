#requires -Version 7.6
BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile("$root/hooks/postprovision.ps1", [ref]$tokens, [ref]$errors)
  if ($errors) { throw 'Postprovision parse failure.' }
  $script:definitions = [scriptblock]::Create((@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) | ForEach-Object { $_.Extent.Text }) -join "`n")
  function Invoke-OfflineOperator {
    param([string]$Action, [string]$Fault = '', [string]$Service = 'Exchange')
    & {
      param($Action, $Fault, $Service)
      . "$script:root/hooks/Common.ps1"
      . $script:definitions
      $state = @{Writes=0; Connections=0; Guards=0; Tokens=0; Browser=0; Failure=''; Selectors=[Collections.Generic.List[object]]::new()}
      $subscription = '11111111-1111-1111-1111-111111111111'
      $tenant = '22222222-2222-2222-2222-222222222222'
      # Native mutation tests exercise maintained helpers and session guard with a
      # deterministic target seam. Real ARM/token paths are tested separately.
      function Assert-AuditOperatorTarget {
        param($SubscriptionId)
        $state.Guards++
        if ($Fault -eq 'disabled' -or ($Fault -eq 'between-writes' -and $state.Writes -ge 1)) { throw 'Fixture current subscription Disabled.' }
        [pscustomobject]@{SubscriptionId=$subscription; TenantId=$tenant; UserPrincipalName='operator@example.test'}
      }
      function Get-AuditScopedAccessToken {
        param($ResourceUrl, $Target)
        $state.Tokens++
        if ($Fault -eq 'token') { throw 'Fixture wrong token tenant.' }
        if ($Target.SubscriptionId -ne $subscription -or $Target.TenantId -ne $tenant) { throw 'Unbound token call.' }
        'fixture-token'
      }
      function az { throw 'Unexpected native CLI.' }
      function Invoke-WebRequest { throw 'Unexpected HTTP.' }
      function Invoke-RestMethod {
        param($Method, $Uri, $Headers, $Body, $ContentType, $MaximumRedirection, $TimeoutSec)
        if ($Uri -notlike 'https://graph.microsoft.com/*') { throw 'Unexpected HTTP URI.' }
        if ($Method -ne 'GET') { $state.Writes++ }
        [pscustomobject]@{id='fixture'}
      }
      function Get-Command {
        [CmdletBinding()]param($Name)
        [pscustomobject]@{CommandType=$(if ($Fault -eq 'command-alias') {'Alias'} else {'Function'});ModuleName=$(if ($Fault -eq 'command-owner') {'tmpEXO_foreign.fixture'} elseif ($Service -eq 'Compliance') {'tmpEXO_compliance.fixture'} else {'tmpEXO_exchange.fixture'})}
      }
      function Get-ConnectionInformation {
        [CmdletBinding()]param()
        $session = [pscustomobject]@{
          TenantID=$tenant; UserPrincipalName='operator@example.test'; State='Connected'; TokenStatus='Active'
          ModuleName=$(if ($Service -eq 'Compliance') {'tmpEXO_compliance.fixture'} else {'tmpEXO_exchange.fixture'}); IsEopSession=($Service -eq 'Compliance'); ModulePrefix=''; DelegatedOrganization=''; CertificateAuthentication=$false
          ConnectionUri=$(if ($Service -eq 'Compliance') {'https://nam12b.ps.compliance.protection.outlook.com'} else {'https://outlook.office365.com'})
          TokenExpiryTimeUTC=[datetimeoffset]::UtcNow.AddHours(1)
        }
        switch ($Fault) {
          'tenant' {$session.TenantID='33333333-3333-3333-3333-333333333333'}
          'fallback-tenant' {$session.TenantID='33333333-3333-3333-3333-333333333333'}
          'actor' {$session.UserPrincipalName='other@example.test'}
          'inactive' {$session.State='Disconnected'}
          'token-inactive' {$session.TokenStatus='Expired'}
          'expiry' {$session.TokenExpiryTimeUTC=[datetimeoffset]::UtcNow.AddMinutes(-1)}
          'prefix' {$session.ModulePrefix='Other'}
          'endpoint' {$session.ConnectionUri='https://example.test'}
          'unknown-kind' {$session.IsEopSession=$null}
          'malformed-auth' {$session.CertificateAuthentication='false'}
          'missing-tenant' {$session.PSObject.Properties.Remove('TenantID')}
          'ambiguous' { $session; $session; return }
          'none' { return }
        }
        $session
      }
      function Connect-ExchangeOnline {
        [CmdletBinding()]param($AccessToken,$UserPrincipalName,[bool]$ShowBanner)
        $state.Connections++
        if (-not $AccessToken) { $state.Browser++ }
        if ($Fault -eq 'fallback-failed' -or ($Fault -eq 'fallback' -and $AccessToken) -or ($Fault -eq 'fallback-tenant' -and $AccessToken)) { throw 'Fixture connection failed.' }
        if ($Fault -eq 'fallback-tenant') { $Fault='tenant' }
      }
      function Connect-IPPSSession {
        [CmdletBinding()]param($AccessToken,$UserPrincipalName,$Organization,$CommandName,[bool]$ShowBanner)
        if (@($CommandName).Count -ne 2 -or $CommandName -notcontains 'New-UnifiedAuditLogRetentionPolicy' -or $CommandName -notcontains 'Get-UnifiedAuditLogRetentionPolicy') { throw 'Purview command import must be restricted.' }
        $state.Connections++
        if ($Fault -eq 'fallback-failed' -or ($Fault -eq 'fallback' -and $UserPrincipalName)) { throw 'Fixture connection failed.' }
      }
      function Get-ServicePrincipal { @() }
      function Get-ManagementRole { [CmdletBinding()]param($Identity) $null }
      function Get-ManagementRoleEntry { [CmdletBinding()]param($Identity) if ($Identity -like '*\*') { [pscustomobject]@{Name='Unrelated'} } }
      function Get-RoleGroup { [CmdletBinding()]param($Identity) $null }
      function Get-RoleGroupMember { param($Identity,$ResultSize) if ($state.Writes -gt 1) { [pscustomobject]@{Id='fixture';Guid='fixture';ExternalDirectoryObjectId='fixture';Name='fixture'} } }
      function Get-UnifiedAuditLogRetentionPolicy { [CmdletBinding()]param($Identity) if ($state.Writes) { [pscustomobject]@{RetentionDuration='TwelveMonths';Priority=10;RecordTypes=@();UserIds=@()} } }
      function New-ServicePrincipal { param($AppId,$ObjectId,$DisplayName) $state.Writes++ }
      function New-ManagementRole { param($Name,$Parent) $state.Writes++ }
      function Remove-ManagementRoleEntry { param($Identity,$Confirm) $state.Writes++ }
      function Add-ManagementRoleEntry { param($Identity,$Parameters) $state.Writes++ }
      function New-RoleGroup { param($Name,$Description,$Roles,$Confirm) $state.Writes++ }
      function Add-RoleGroupMember { param($Identity,$Member,$Confirm) $state.Writes++ }
      function New-UnifiedAuditLogRetentionPolicy { param($Name,$Description,$RetentionDuration,$Priority) $state.Writes++ }
      try {
        switch ($Action) {
          'service-principal' { Ensure-ExchangeServicePrincipal -ManagedIdentityObjectId fixture -ManagedIdentityAppId fixture }
          'mailbox-role' { Ensure-MailboxAuditingRole }
          'role-group' { Ensure-RoleGroupMembership -ManagedIdentityObjectId fixture }
          'retention' { Ensure-AuditRetentionPolicy -PolicyName fixture }
          'graph' { $null=Invoke-GraphRest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals/fixture/appRoleAssignments' -Body '{}' }
          'exchange-connect' { Connect-ExchangeForBootstrap }
          'compliance-connect' { $state.Connected=Connect-ComplianceForBootstrap -Organization 'fixture.onmicrosoft.com' }
          default { throw 'Unexpected action.' }
        }
      } catch { $state.Failure=$_.Exception.Message }
      [pscustomobject]$state
    } $Action $Fault $Service
  }
}

Describe 'Actual operator native mutation helpers' {
  It 'refuses <Action> for <Fault> before any mutation' -ForEach @(
    foreach ($action in @('service-principal','mailbox-role','role-group','retention')) {
      foreach ($fault in @('tenant','actor','inactive','token-inactive','expiry','prefix','endpoint','unknown-kind','missing-tenant','ambiguous','none','disabled','command-owner','command-alias','malformed-auth')) {
        @{Action=$action; Fault=$fault; Service=$(if ($action -eq 'retention') {'Compliance'} else {'Exchange'})}
      }
    }
  ) {
    $result=Invoke-OfflineOperator -Action $Action -Fault $Fault -Service $Service
    $result.Failure | Should -Not -BeNullOrEmpty
    $result.Writes | Should -Be 0
  }
  It 'allows valid <Action> through its real mutation boundary' -ForEach @('service-principal','mailbox-role','role-group','retention') {
    $result=Invoke-OfflineOperator -Action $_ -Service $(if ($_ -eq 'retention') {'Compliance'} else {'Exchange'})
    $result.Failure | Should -BeNullOrEmpty
    $result.Writes | Should -BeGreaterThan 0
  }
  It 'rechecks state between writes in <Action>' -ForEach @('mailbox-role','role-group') {
    $result=Invoke-OfflineOperator -Action $_ -Fault between-writes
    $result.Failure | Should -Match 'Disabled'
    $result.Writes | Should -Be 1
  }
  It 'prevents Graph HTTP writes on target or token mismatch <_>' -ForEach @('disabled','token') {
    $result=Invoke-OfflineOperator -Action graph -Fault $_
    $result.Failure | Should -Not -BeNullOrEmpty
    $result.Writes | Should -Be 0
  }
}
Describe 'Actual native connection and fallback boundaries' {
  It 'checks the native session after successful <Action>' -ForEach @(
    @{Action='exchange-connect';Service='Exchange'},@{Action='compliance-connect';Service='Compliance'}
  ) {
    foreach ($fault in @('tenant','actor','inactive')) {
      $result=Invoke-OfflineOperator -Action $Action -Service $Service -Fault $fault
      $result.Failure | Should -Match 'Cannot verify'
      $result.Connections | Should -Be 1
      $result.Writes | Should -Be 0
    }
  }
  It 'supports the existing normal Exchange fallback with a verified session' {
    $result=Invoke-OfflineOperator -Action exchange-connect -Fault fallback
    $result.Failure | Should -BeNullOrEmpty
    $result.Connections | Should -Be 2
    $result.Browser | Should -Be 1
  }
  It 'rejects the wrong tenant after a normal browser fallback' {
    $result=Invoke-OfflineOperator -Action exchange-connect -Fault fallback-tenant
    $result.Failure | Should -Match 'Cannot verify'
    $result.Connections | Should -Be 2
    $result.Writes | Should -Be 0
  }
  It 'does not fallback on wrong token metadata' {
    $result=Invoke-OfflineOperator -Action exchange-connect -Fault token
    $result.Failure | Should -Match 'token tenant'
    $result.Connections | Should -Be 0
  }
  It 'stops after unsuccessful Exchange fallback without writes' {
    $result=Invoke-OfflineOperator -Action exchange-connect -Fault fallback-failed
    $result.Failure | Should -Match 'could not complete'
    $result.Connections | Should -Be 2
    $result.Writes | Should -Be 0
  }
  It 'preserves successful Purview primary and fallback booleans' -ForEach @('','fallback') {
    $result=Invoke-OfflineOperator -Action compliance-connect -Service Compliance -Fault $_
    $result.Failure | Should -BeNullOrEmpty
    $result.Connected | Should -BeTrue
  }
  It 'preserves unavailable Purview as a degraded false result' {
    $result=Invoke-OfflineOperator -Action compliance-connect -Service Compliance -Fault fallback-failed
    $result.Failure | Should -BeNullOrEmpty
    $result.Connected | Should -BeFalse
    $result.Writes | Should -Be 0
  }
}

Describe 'Safety failures cannot recover into later writes' {
  BeforeAll {
    $source=Get-Content "$root/hooks/postprovision.ps1" -Raw
    $start=$source.IndexOf('$runbookFailures =')
    $script:jobDispatch=[scriptblock]::Create($source.Substring($start))
  }
  It 'rethrows target failures before the Graph domain fallback' {
    & {
      . "$script:root/hooks/Common.ps1"
      . $script:definitions
      function Invoke-GraphRest { throw (New-AuditTargetGuardException -Message 'Fixture guard failed.') }
      function Get-AcceptedDomain { throw 'Unexpected domain fallback.' }
      { Get-ExchangeOrganizationDomain } | Should -Throw 'Fixture guard failed.'
    }
  }
  It 'stops before the later validation job after remediation guard failure' {
    & {
      . "$script:root/hooks/Common.ps1"
      $subscriptionId='fixture';$resourceGroupName='fixture';$automationAccountName='fixture';$validateConfigurationRunbookName='validate'
      $calls=[Collections.Generic.List[string]]::new()
      function Start-AutomationRunbookAndWait {
        param($SubscriptionId,$ResourceGroupName,$AutomationAccountName,$RunbookName)
        $calls.Add($RunbookName)
        if ($RunbookName -eq 'Enable-AdvancedAuditing') { throw (New-AuditTargetGuardException -Message 'Fixture guard failed.') }
      }
      { & $script:jobDispatch } | Should -Throw 'Fixture guard failed.'
      @($calls) | Should -Be @('Enable-AdvancedAuditing')
    }
  }
  It 'preserves ordinary fatal mailbox failures while collecting validation results' {
    & {
      . "$script:root/hooks/Common.ps1"
      $subscriptionId='fixture';$resourceGroupName='fixture';$automationAccountName='fixture';$validateConfigurationRunbookName='validate'
      $calls=[Collections.Generic.List[string]]::new()
      function Start-AutomationRunbookAndWait {
        param($SubscriptionId,$ResourceGroupName,$AutomationAccountName,$RunbookName)
        $calls.Add($RunbookName)
        if ($RunbookName -eq 'Enable-AdvancedAuditing') { throw 'Fixture mailbox failure.' }
      }
      { & $script:jobDispatch } | Should -Throw '*Fixture mailbox failure*'
      @($calls) | Should -Be @('Enable-AdvancedAuditing','validate')
    }
  }
}
