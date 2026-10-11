#Requires -Version 7.6
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/vendor/Azd.DeploymentValidation/Azd.DeploymentValidation.psd1" -Force

function Assert-AuditValidationTarget {
    param($Target)
    try {
        foreach($name in @('subscriptionId','tenantId','principalId')){if(-not [guid]::TryParse([string]$Target.$name,[ref]([guid]::Empty))){throw 'Invalid'}}
        if($Target.account -notmatch '^[^\s@]+@[^\s@]+$' -or $Target.resourceGroup -notmatch '^[A-Za-z0-9_-]{1,90}$' -or $Target.automationAccount -notmatch '^[A-Za-z0-9_-]{3,50}$' -or $Target.alertsEnabled -isnot [bool]){throw 'Invalid'}
        if(@($Target.PSObject.Properties.Name|Where-Object{$_ -notin @('subscriptionId','tenantId','principalId','account','resourceGroup','automationAccount','alertsEnabled','workspaceId','actionGroupId')}).Count){throw 'Invalid'}
        if($Target.alertsEnabled){
            foreach($name in @('workspaceId','actionGroupId')){
                $suffix=if($name -eq 'workspaceId'){'Microsoft.OperationalInsights/workspaces'}else{'Microsoft.Insights/actionGroups'}
                $pattern='^/subscriptions/'+[regex]::Escape($Target.subscriptionId)+'/resourceGroups/[A-Za-z0-9_-]+/providers/'+[regex]::Escape($suffix)+'/[A-Za-z0-9_-]+$'
                if($Target.$name -notmatch $pattern){throw 'Invalid'}
            }
        }
    }catch{throw 'Invalid validation target; supply exact reviewed account, tenant, subscription, principal and resource IDs.'}
}

function Read-AuditArm {
    param($Target,[string]$Id,[string]$ApiVersion='2023-11-01')
    if($Id -notmatch ('^/subscriptions/'+[regex]::Escape($Target.subscriptionId)+'/resourceGroups/[A-Za-z0-9_-]+/providers/[A-Za-z0-9./_-]+$')){throw 'ReadBindingFailed'}
    try{
        $text=& az rest --method GET --url "https://management.azure.com$($Id)?api-version=$ApiVersion" --subscription $Target.subscriptionId --output json --only-show-errors 2>$null
        if($LASTEXITCODE -ne 0){throw 'Unavailable'}
        $dto=($text -join "`n")|ConvertFrom-Json -DateKind String -Depth 64 -ErrorAction Stop
        if($dto.id -ine $Id){throw 'WrongIdentity'}
        return $dto
    }catch{throw 'BoundReadUnavailable'}
}

function Invoke-AuditBoundProbe {
    param($Target,[string]$Probe)
    $accountId='/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}' -f $Target.subscriptionId,$Target.resourceGroup,$Target.automationAccount
    if($Probe -eq 'context'){
        try{
            $text=& az account show --output json --only-show-errors 2>$null
            if($LASTEXITCODE -ne 0){throw 'Unavailable'}
            $account=($text -join "`n")|ConvertFrom-Json -DateKind String
            if($account.id -ine $Target.subscriptionId -or $account.tenantId -ine $Target.tenantId -or $account.user.name -ine $Target.account -or $account.user.type -ne 'user'){throw 'Mismatch'}
            return (New-AzdCheckOutcome -Status pass -Summary 'Exact selected cached user context matches.')
        }catch{return (New-AzdCheckOutcome -Status fail -Summary 'Selected cached account, tenant or subscription unavailable or mismatched; no setup reads authorized.')}
    }
    try{
        switch($Probe){
            'account' {
                $account=Read-AuditArm $Target $accountId '2024-10-23'
                if($account.identity.principalId -ine $Target.principalId -or $account.identity.tenantId -ine $Target.tenantId){throw 'Wrong identity'}
                return (New-AzdCheckOutcome -Status pass -Summary 'Exact Automation account and managed identity observed.')
            }
            'runbooks' {
                foreach($name in @('Enable-AdvancedAuditing','Validate-ExchangeManagedIdentity','Validate-AdvancedAuditingConfiguration')){
                    $runbook=Read-AuditArm $Target ($accountId+'/runbooks/'+$name) '2024-10-23'
                    if($runbook.properties.state -ne 'Published' -or $runbook.properties.runtimeEnvironment -ne 'PowerShell-76-AdvancedAuditing'){throw 'Incomplete metadata'}
                }
                return (New-AzdCheckOutcome -Status pass -Summary 'All three audit runbooks published and linked to PowerShell 7.6; no Exchange execution proved.')
            }
            'schedule' {
                $schedule=Read-AuditArm $Target ($accountId+'/schedules/advanced-auditing-daily')
                if($schedule.properties.frequency -ne 'Day' -or $schedule.properties.interval -ne 1){throw 'Incomplete metadata'}
                return (New-AzdCheckOutcome -Status pass -Summary 'Daily schedule metadata checked; execution and linkage remain separate evidence.')
            }
            'retention-setup' {
                $state=Read-AuditArm $Target ($accountId+'/variables/AuditRetentionSetupState')
                $raw=$state.properties.value
                if($raw -isnot [string] -or $raw.Length -gt 4096){throw 'Invalid state'}
                $decoded=$raw|ConvertFrom-Json -DateKind String
                if($decoded -isnot [string]){throw 'Invalid state'}
                $observation=$decoded|ConvertFrom-Json -DateKind String
                if($observation.accountId -ine $accountId -or $observation.kind -cne 'advancedAuditing.retentionSetup' -or $observation.schemaVersion -cne '1.0' -or $observation.setupState -cnotin @('setupVerified','setupUnavailable','setupFailed')){throw 'Invalid state'}
                $stamp=[DateTimeOffset]::Parse($observation.observedAt,[Globalization.CultureInfo]::InvariantCulture)
                $code=if($stamp -gt [DateTimeOffset]::UtcNow.AddMinutes(5)){'unknown'}elseif($stamp -lt [DateTimeOffset]::UtcNow.AddDays(-7)){'stale'}elseif($observation.setupState -eq 'setupVerified'){'bootstrapVerified'}else{'degraded'}
                return (New-AzdCheckOutcome -Status warning -Summary 'Bootstrap observation only; actual Purview retention requires separate authorized validation.' -Actual $code)
            }
            'operational-routing' {
                $null=Read-AuditArm $Target $Target.workspaceId '2023-09-01'
                $null=Read-AuditArm $Target $Target.actionGroupId '2023-01-01'
                $diagnostic=Read-AuditArm $Target ($accountId+'/providers/Microsoft.Insights/diagnosticSettings/advanced-auditing-operational') '2021-05-01-preview'
                if($diagnostic.properties.workspaceId -ine $Target.workspaceId){throw 'Wrong workspace'}
                foreach($category in @('JobLogs','JobStreams')){if(@($diagnostic.properties.logs|Where-Object{$_.category -eq $category -and $_.enabled -eq $true}).Count -ne 1){throw 'Missing category'}}
                return (New-AzdCheckOutcome -Status pass -Summary 'Exact optional log destinations/categories observed; ingestion and action-group delivery unverified.')
            }
            'operational-disabled' { return (New-AzdCheckOutcome -Status skipped -Summary 'Operational alerts disabled; no optional resource/destination read.') }
            'exchange-gates' { return (New-AzdCheckOutcome -Status warning -Summary 'Exchange connection, mailbox auditing/bypass, ingestion and actual Purview retention require separate authorized audit-specific validation. See AUD-002 and issue #1.') }
            default {throw 'Unknown probe'}
        }
    }catch{
        $status=if($Probe -eq 'account'){'fail'}else{'warning'}
        New-AzdCheckOutcome -Status $status -Summary 'Bound metadata unavailable, incomplete or invalid; readiness is not established. No raw provider details retained.'
    }
}

function New-AuditValidationDefinitions {
    param($Target)
    Assert-AuditValidationTarget $Target
    # Snapshot caller data; every action carries that same target. A separate
    # definition set cannot replace another set's target or cached-context gate.
    $boundTarget=$Target|ConvertTo-Json -Depth 16|ConvertFrom-Json -DateKind String
    $ownerModule=$ExecutionContext.SessionState.Module
    $specs=@(
        @{id='context';phase='context';depends=@()},
        @{id='account';phase='infrastructure';depends=@('audit.context')},
        @{id='runbooks';phase='infrastructure';depends=@('audit.account')},
        @{id='schedule';phase='infrastructure';depends=@('audit.account')}
    )
    if($boundTarget.alertsEnabled){
        $specs+=@(@{id='retention-setup';phase='configuration';depends=@('audit.account')},@{id='operational-routing';phase='infrastructure';depends=@('audit.account')})
    }else{$specs+=@{id='operational-disabled';phase='configuration';depends=@()}}
    $specs+=@{id='exchange-gates';phase='runtime';depends=@()}
    foreach($spec in $specs){
        $probeId=$spec.id
        # Closure retains immutable scalar target snapshot. Explicit module
        # dispatch preserves the native/provider trust boundary and test guards.
        $action={ & $ownerModule {param($bound,$probe) Invoke-AuditBoundProbe -Target $bound -Probe $probe} $boundTarget $probeId }.GetNewClosure()
        $effect=if($probeId -in @('operational-disabled','exchange-gates')){'none'}else{'readOnly'}
        New-AzdValidationCheckDefinition -Id ('audit.'+$probeId) -Phase $spec.phase -Title ('Audit '+$probeId) -Summary 'Bounded read-only observation; retain audit-specific acceptance separately.' -Action $action -DependsOn $spec.depends -SideEffect $effect
    }
}

function Invoke-AuditDeploymentValidation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Target,[switch]$Plan)
    Assert-AuditValidationTarget $Target
    $Target=$Target|ConvertTo-Json -Depth 16|ConvertFrom-Json -DateKind String
    $started=[DateTimeOffset]::UtcNow
    $definitions=@(New-AuditValidationDefinitions $Target)
    $checks=@(Invoke-AzdValidationSet -Definitions $definitions -Plan:$Plan)
    New-AzdValidationReport -TemplateName 'azd-advanced-auditing' -TemplateVersion '1.0' -Mode $(if($Plan){'plan'}else{'verify'}) -StartedAt $started -Checks $checks -Environment @{tenantId=$Target.tenantId;subscriptionId=$Target.subscriptionId;resourceGroup=$Target.resourceGroup;metadata=@{automationAccount=$Target.automationAccount}} -NextSteps @('Run no remediation from this report. Preserve the separate supported-platform audit acceptance gate.')
}
Export-ModuleMember -Function Invoke-AuditDeploymentValidation
