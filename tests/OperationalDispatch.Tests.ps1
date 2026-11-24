BeforeAll {
    foreach($name in @('az','Invoke-WebRequest','Invoke-RestMethod','Connect-ExchangeOnline','Connect-IPPSSession','Connect-MgGraph','Connect-AzAccount')){Set-Item ('Function:global:'+$name) -Value {throw 'Offline fixture forbids native/provider fallback.'}}
    $source=Get-Content "$PSScriptRoot/../hooks/postprovision.ps1" -Raw
    $start=$source.IndexOf('$operationalAlertsEnabled = $false')
    $end=$source.IndexOf("Write-Section -Message 'Granting managed identity Exchange application access'",$start)
    if($start -lt 0 -or $end -lt $start){throw 'Actual retention dispatch boundary not found'}
    $script:branch=[scriptblock]::Create($source.Substring($start,$end-$start))
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/../hooks/postprovision.ps1",[ref]$tokens,[ref]$errors)
    $script:mainRunbookCall=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-AutomationRunbookAndWait'},$true)|Where-Object{$_.Extent.Text -match '@runbookStartParameters'})
    if($script:mainRunbookCall.Count -ne 1){throw 'Expected one remediation runbook start call.'}
    $dispatchStart=$source.IndexOf('$runbookStartParameters = @{')
    $dispatchTry=$source.IndexOf("Write-Section -Message 'Running advanced auditing remediation runbook'",$dispatchStart)
    $dispatchEnd=$source.IndexOf('catch {',$dispatchTry)
    if($dispatchStart -lt 0 -or $dispatchTry -lt $dispatchStart -or $dispatchEnd -lt $dispatchTry){throw 'Expected the remediation runbook dispatch parameter block.'}
    $script:runbookDispatch=[scriptblock]::Create($source.Substring($dispatchStart,$dispatchEnd-$dispatchStart)+'catch { throw }')
    function Write-Section { param($Message) }
    function New-AuditOperatorContextException { param($Message) $exception=[System.InvalidOperationException]::new($Message);$exception.Data['AuditOperatorContext']=$true;return $exception }
    function Test-AuditOperatorContextException { param($ErrorRecord) return ($ErrorRecord.Exception.Data['AuditOperatorContext'] -eq $true) }
    function Start-AutomationRunbookAndWait {
        param([string]$SubscriptionId,[string]$ResourceGroupName,[string]$AutomationAccountName,[string]$RunbookName,[hashtable]$Parameters)
        $script:capturedRunbookStartArguments=@{}
        foreach($key in $PSBoundParameters.Keys){$script:capturedRunbookStartArguments[$key]=$PSBoundParameters[$key]}
    }
    function Get-ValueFromEnvironment {throw 'Optional flag must not use process-first helper'}
    function Ensure-AuditRetentionPolicy {param($PolicyName) $script:policyCalls++; if($script:contextFailure){throw (New-AuditOperatorContextException -Message 'Fixture target mismatch.')}; if($script:failPolicy){throw 'fixture policy failure'}}
    function Save-AuditRetentionSetupState {param($Enabled,$SetupState,$SubscriptionId,$TenantId,$ResourceGroupName,$AutomationAccountName) $script:states.Add("${Enabled}:${SetupState}")}
}
Describe 'Actual postprovision retention dispatch block' {
    BeforeEach {
        $script:failPolicy=$false;$script:contextFailure=$false;$script:states=[Collections.Generic.List[string]]::new();$script:policyCalls=0
        $azdValues=@{OPERATIONAL_ALERTS_ENABLED='true'};$subscriptionId='cccccccc-cccc-cccc-cccc-cccccccccccc';$tenantId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';$resourceGroupName='fixture-rg';$automationAccountName='fixture-audit';$retentionPolicyName='fixture-policy'
        $degradedConditions=[Collections.Generic.List[string]]::new()
    }
    It 'records verified bootstrap after the existing policy succeeds' {
        $complianceConnected=$true
        . $script:branch
        @($script:states)|Should -Be @('True:setupVerified')
    }
    It 'records unavailable bootstrap without attempting policy writes' {
        $complianceConnected=$false;$script:failPolicy=$true
        . $script:branch
        @($script:states)|Should -Be @('True:setupUnavailable')
        $degradedConditions.Count|Should -Be 1
    }
    It 'records failed bootstrap and preserves the policy failure' {
        $complianceConnected=$true;$script:failPolicy=$true
        {. $script:branch}|Should -Throw 'fixture policy failure'
        @($script:states)|Should -Be @('True:setupFailed')
    }
    It 'does not write failed retention state after a target-context failure' {
        $complianceConnected=$true
        $script:contextFailure=$true
        { . $script:branch } | Should -Throw 'Fixture target mismatch.'
        $script:states.Count | Should -Be 0
    }
    It 'ignores conflicting true process environment when deployed false, making zero optional save calls' {
        $complianceConnected=$false;$azdValues.OPERATIONAL_ALERTS_ENABLED='false'
        $previous=[Environment]::GetEnvironmentVariable('OPERATIONAL_ALERTS_ENABLED','Process')
        try {
            [Environment]::SetEnvironmentVariable('OPERATIONAL_ALERTS_ENABLED','true','Process')
            . $script:branch
            $script:states.Count|Should -Be 0
        } finally { [Environment]::SetEnvironmentVariable('OPERATIONAL_ALERTS_ENABLED',$previous,'Process') }
    }
    It 'preserves hook-only updates when an older deployment has no monitoring output' {
        $complianceConnected=$true
        $azdValues.Remove('OPERATIONAL_ALERTS_ENABLED')
        {. $script:branch}|Should -Not -Throw
        $operationalAlertsEnabled|Should -BeFalse
        $script:policyCalls|Should -Be 1
        $script:states.Count|Should -Be 0
    }
    It 'refuses malformed deployed output before any optional save' {
        $complianceConnected=$false
        $azdValues.OPERATIONAL_ALERTS_ENABLED='SECRET-SENTINEL'
        {. $script:branch}|Should -Throw 'Deployed OPERATIONAL_ALERTS_ENABLED output is invalid*'
        $script:states.Count|Should -Be 0
    }
    It 'preserves old published runbooks when the older deployment has no monitoring output' {
        $hasOperationalAlertsOutput=$false
        $operationalAlertsEnabled=$false
        $subscriptionId='cccccccc-cccc-cccc-cccc-cccccccccccc';$resourceGroupName='fixture-rg';$automationAccountName='fixture-audit'
        $script:capturedRunbookStartArguments=$null
        & $script:runbookDispatch
        $script:capturedRunbookStartArguments.RunbookName|Should -BeExactly 'Enable-AdvancedAuditing'
        $script:capturedRunbookStartArguments.Contains('Parameters')|Should -BeFalse
        $script:mainRunbookCall[0].Extent.Text|Should -Match 'Start-AutomationRunbookAndWait @runbookStartParameters'
    }
    It 'passes the exact selected deployed monitoring mode after the output exists' {
        $hasOperationalAlertsOutput=$true
        $operationalAlertsEnabled=$true
        $subscriptionId='cccccccc-cccc-cccc-cccc-cccccccccccc';$resourceGroupName='fixture-rg';$automationAccountName='fixture-audit'
        $script:capturedRunbookStartArguments=$null
        & $script:runbookDispatch
        $script:capturedRunbookStartArguments.Parameters.OperationalAlertsEnabled|Should -BeExactly 'true'
    }
}
Describe 'Actual postprovision validation job dispatch' {
    BeforeAll {
        $source=Get-Content "$PSScriptRoot/../hooks/postprovision.ps1" -Raw
        $start=$source.IndexOf('$runbookFailures =')
        if($start -lt 0){throw 'Expected postprovision validation job dispatch.'}
        $script:jobDispatch=[scriptblock]::Create($source.Substring($start))
    }
    BeforeEach {
        $subscriptionId='cccccccc-cccc-cccc-cccc-cccccccccccc';$resourceGroupName='fixture-rg';$automationAccountName='fixture-audit';$validateConfigurationRunbookName='validate'
        $hasOperationalAlertsOutput=$false;$operationalAlertsEnabled=$false
        $script:jobCalls=[Collections.Generic.List[string]]::new();$script:jobFailure=''
        function Start-AutomationRunbookAndWait {
            param($SubscriptionId,$ResourceGroupName,$AutomationAccountName,$RunbookName,$Parameters)
            $script:jobCalls.Add($RunbookName)
            if($RunbookName -eq 'Enable-AdvancedAuditing' -and $script:jobFailure -eq 'guard') { throw (New-AuditOperatorContextException -Message 'Fixture target mismatch.') }
            if($RunbookName -eq 'Enable-AdvancedAuditing' -and $script:jobFailure -eq 'ordinary') { throw 'Fixture mailbox failure.' }
        }
    }
    It 'stops before the validation job after a target-context failure' {
        $script:jobFailure='guard'
        { & $script:jobDispatch } | Should -Throw 'Fixture target mismatch.'
        @($script:jobCalls) | Should -Be @('Enable-AdvancedAuditing')
    }
    It 'preserves ordinary remediation failure reporting and runs validation' {
        $script:jobFailure='ordinary'
        { & $script:jobDispatch } | Should -Throw '*Fixture mailbox failure*'
        @($script:jobCalls) | Should -Be @('Enable-AdvancedAuditing','validate')
    }
}
AfterAll {
    foreach($name in @('az','Invoke-WebRequest','Invoke-RestMethod','Connect-ExchangeOnline','Connect-IPPSSession','Connect-MgGraph','Connect-AzAccount')){Remove-Item ('Function:global:'+$name) -ErrorAction SilentlyContinue}
}
