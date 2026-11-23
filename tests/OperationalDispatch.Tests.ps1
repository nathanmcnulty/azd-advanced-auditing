BeforeAll {
    foreach($name in @('az','Invoke-WebRequest','Invoke-RestMethod','Connect-ExchangeOnline','Connect-IPPSSession','Connect-MgGraph','Connect-AzAccount')){Set-Item ('Function:global:'+$name) -Value {throw 'Offline fixture forbids native/provider fallback.'}}
    $source=Get-Content "$PSScriptRoot/../hooks/postprovision.ps1" -Raw
    $start=$source.IndexOf('$operationalAlertsEnabled = $false')
    $end=$source.IndexOf("Write-Section -Message 'Granting managed identity Exchange application access'",$start)
    if($start -lt 0 -or $end -lt $start){throw 'Actual retention dispatch boundary not found'}
    $script:branch=[scriptblock]::Create($source.Substring($start,$end-$start))
    function Get-ValueFromEnvironment {throw 'Optional flag must not use process-first helper'}
    function Ensure-AuditRetentionPolicy {param($PolicyName) if($script:failPolicy){throw 'fixture policy failure'}}
    function Save-AuditRetentionSetupState {param($Enabled,$SetupState,$SubscriptionId,$ResourceGroupName,$AutomationAccountName) $script:states.Add("${Enabled}:${SetupState}")}
}
Describe 'Actual postprovision retention dispatch block' {
    BeforeEach {
        $script:failPolicy=$false;$script:states=[Collections.Generic.List[string]]::new()
        $azdValues=@{OPERATIONAL_ALERTS_ENABLED='true'};$subscriptionId='cccccccc-cccc-cccc-cccc-cccccccccccc';$resourceGroupName='fixture-rg';$automationAccountName='fixture-audit';$retentionPolicyName='fixture-policy'
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
    It 'ignores conflicting true process environment when deployed false, making zero optional save calls' {
        $complianceConnected=$false;$azdValues.OPERATIONAL_ALERTS_ENABLED='false'
        $previous=[Environment]::GetEnvironmentVariable('OPERATIONAL_ALERTS_ENABLED','Process')
        try {
            [Environment]::SetEnvironmentVariable('OPERATIONAL_ALERTS_ENABLED','true','Process')
            . $script:branch
            $script:states.Count|Should -Be 0
        } finally { [Environment]::SetEnvironmentVariable('OPERATIONAL_ALERTS_ENABLED',$previous,'Process') }
    }
    It 'refuses missing or malformed deployed output before any optional save' -ForEach @('missing','SECRET-SENTINEL') {
        $complianceConnected=$false
        if($_ -eq 'missing'){$azdValues.Remove('OPERATIONAL_ALERTS_ENABLED')}else{$azdValues.OPERATIONAL_ALERTS_ENABLED=$_}
        {. $script:branch}|Should -Throw 'Deployed OPERATIONAL_ALERTS_ENABLED output is missing or invalid*'
        $script:states.Count|Should -Be 0
    }
}
AfterAll {
    foreach($name in @('az','Invoke-WebRequest','Invoke-RestMethod','Connect-ExchangeOnline','Connect-IPPSSession','Connect-MgGraph','Connect-AzAccount')){Remove-Item ('Function:global:'+$name) -ErrorAction SilentlyContinue}
}
