#Requires -Version 7.6
function global:az { throw 'Offline fixture forbids any native Azure CLI fallback.' }
foreach($name in @('Invoke-WebRequest','Invoke-RestMethod','Connect-ExchangeOnline','Connect-IPPSSession','Connect-MgGraph','Connect-AzAccount')){
    Set-Item ('Function:global:'+$name) -Value {throw 'Offline fixture forbids any HTTP/auth/Exchange provider fallback.'}
}
Import-Module "$PSScriptRoot/../scripts/Audit.Validation.psm1" -Force
BeforeAll {
    $root=Split-Path $PSScriptRoot -Parent
}
Describe 'Read-only deployment adapter' {
    InModuleScope Audit.Validation {
        BeforeEach {
            $script:t=[pscustomobject]@{subscriptionId='cccccccc-cccc-cccc-cccc-cccccccccccc';tenantId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';principalId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';account='reader@example.invalid';resourceGroup='fixture-rg';automationAccount='fixture-audit';alertsEnabled=$false}
            $script:accountId="/subscriptions/$($t.subscriptionId)/resourceGroups/$($t.resourceGroup)/providers/Microsoft.Automation/automationAccounts/$($t.automationAccount)"
            $script:foreign=$false;$script:contextMismatch=''
            $script:urls=[Collections.Generic.List[string]]::new()
            $script:contextArguments=[Collections.Generic.List[object]]::new()
            Mock az {
                $global:LASTEXITCODE=0
                if($args[0] -eq 'account'){
                    $script:contextArguments.Add([string[]]$args)
                    if($args.Count -ne 7 -or $args[1] -cne 'show' -or $args[2] -cne '--subscription' -or $args[4] -cne '--output' -or $args[5] -cne 'json' -or $args[6] -cne '--only-show-errors'){throw 'Unexpected context selector arguments'}
                    $context=@{id=[string]$args[3];tenantId=$t.tenantId;user=@{name=$t.account;type='user'}}
                    switch($script:contextMismatch){
                        'subscription' {$context.id='dddddddd-dddd-dddd-dddd-dddddddddddd'}
                        'tenant' {$context.tenantId='dddddddd-dddd-dddd-dddd-dddddddddddd'}
                        'user' {$context.user.name='foreign@example.invalid'}
                        'type' {$context.user.type='servicePrincipal'}
                    }
                    return ($context|ConvertTo-Json -Compress)
                }
                if($args[0] -ne 'rest' -or $args[2] -cne 'GET' -or $args -notcontains '--subscription'){throw 'Unexpected write/native command'}
                $url=[string]$args[4];$id=$url.Replace('https://management.azure.com','').Split('?')[0]
                $script:urls.Add($url)
                $dto=@{id=$id;properties=@{state='Published';runtimeEnvironment='PowerShell-76-AdvancedAuditing';frequency='Day';interval=1};identity=@{principalId=$t.principalId;tenantId=$t.tenantId}}
                if($script:foreign){$dto.id='/subscriptions/foreign/resourceGroups/secret/providers/secret';$dto.raw='SECRET-SENTINEL'}
                if($id -like '*/variables/AuditRetentionSetupState'){
                    $observation=@{kind='advancedAuditing.retentionSetup';schemaVersion='1.0';accountId=$script:accountId;observedAt=[DateTimeOffset]::UtcNow.ToString('o');setupState='setupUnavailable'}|ConvertTo-Json -Compress
                    $dto.properties.value=ConvertTo-Json -InputObject $observation -Compress
                }
                if($id -like '*/diagnosticSettings/*'){$dto.properties.workspaceId=$script:t.workspaceId;$dto.properties.logs=@(@{category='JobLogs';enabled=$true},@{category='JobStreams';enabled=$true})}
                return ($dto|ConvertTo-Json -Depth 10 -Compress)
            }
        }
        It 'plans with zero native dispatch and real standard report schema' {
            $r=Invoke-AuditDeploymentValidation -Target $t -Plan
            Should -Invoke az -Times 0
            @($r.checks|Where-Object status -eq 'planned').Count|Should -Be 6
            ($r|ConvertTo-Json -Depth 64)|Test-Json -SchemaFile "$PSScriptRoot/../scripts/vendor/Azd.DeploymentValidation/deployment-validation.schema.json"|Should -BeTrue
        }
        It 'checks actual wire DTOs while preserving Exchange/Purview as a separate warning gate' {
            $r=Invoke-AuditDeploymentValidation -Target $t
            @($r.checks|Where-Object status -eq 'pass').Count|Should -Be 4
            ($r.checks|Where-Object id -eq 'audit.exchange-gates').status|Should -Be 'warning'
            ($r.checks|Where-Object id -eq 'audit.operational-disabled').status|Should -Be 'skipped'
            Should -Invoke az -Times 6 -Exactly
        }
        It 'passes the exact selected subscription in the actual context argv' {
            $r=Invoke-AuditDeploymentValidation -Target $t
            ($r.checks|Where-Object id -eq 'audit.context').status|Should -Be 'pass'
            $script:contextArguments.Count|Should -Be 1
            ($script:contextArguments[0] -join '|')|Should -BeExactly "account|show|--subscription|$($t.subscriptionId)|--output|json|--only-show-errors"
        }
        It 'stops all ARM reads on wrong returned <Field>' -ForEach @(
            @{Field='subscription'},@{Field='tenant'},@{Field='user'},@{Field='type'}
        ) {
            $script:contextMismatch=$Field
            $r=Invoke-AuditDeploymentValidation -Target $t
            ($r.checks|Where-Object id -eq 'audit.context').status|Should -Be 'fail'
            Should -Invoke az -Times 1 -Exactly
            $script:contextArguments.Count|Should -Be 1
            $script:urls.Count|Should -Be 0
            Should -Invoke az -Times 0 -Exactly -ParameterFilter {$args[0] -eq 'rest'}
        }
        It 'rejects foreign resource response identity and never copies raw provider values' {
            $script:foreign=$true
            $r=Invoke-AuditDeploymentValidation -Target $t
            ($r|ConvertTo-Json -Depth 64)|Should -Not -Match 'SECRET-SENTINEL|subscriptions/foreign'
            ($r.checks|Where-Object id -eq 'audit.account').status|Should -Be 'fail'
        }
        It 'sanitizes CLI exceptions and never attempts authentication' {
            Mock az {throw 'SECRET-SENTINEL Bearer fixture https://secret.invalid/?sig=fixture'}
            $r=Invoke-AuditDeploymentValidation -Target $t
            ($r|ConvertTo-Json -Depth 64)|Should -Not -Match 'SECRET-SENTINEL|secret.invalid|Bearer fixture'
            Should -Invoke az -Times 1 -Exactly
        }
        It 'rejects path injection and foreign subscription destinations before CLI dispatch' {
            $t.automationAccount='../secret'
            {Invoke-AuditDeploymentValidation -Target $t}|Should -Throw 'Invalid validation target*'
            Should -Invoke az -Times 0
        }
        It 'reads optional bound destinations and literal-encoded bootstrap state without claiming effective retention' {
            $t.alertsEnabled=$true
            $t|Add-Member workspaceId "/subscriptions/$($t.subscriptionId)/resourceGroups/monitor-rg/providers/Microsoft.OperationalInsights/workspaces/fixture-law"
            $t|Add-Member actionGroupId "/subscriptions/$($t.subscriptionId)/resourceGroups/monitor-rg/providers/Microsoft.Insights/actionGroups/fixture-group"
            $r=Invoke-AuditDeploymentValidation -Target $t
            ($r.checks|Where-Object id -eq 'audit.retention-setup').actual|Should -Be 'degraded'
            ($r.checks|Where-Object id -eq 'audit.retention-setup').status|Should -Be 'warning'
            ($r.checks|Where-Object id -eq 'audit.operational-routing').status|Should -Be 'pass'
            Should -Invoke az -Times 10 -Exactly
        }
        It 'retains each target snapshot when another definitions set and caller mutation occur later' {
            $firstSubscription=$t.subscriptionId
            $first=@(New-AuditValidationDefinitions $t)
            $t.resourceGroup='later-rg'
            $t.subscriptionId='dddddddd-dddd-dddd-dddd-dddddddddddd'
            $secondSubscription=$t.subscriptionId
            $second=@(New-AuditValidationDefinitions $t)
            $firstResult=Invoke-AzdValidationSet -Definitions $first
            ($firstResult|Where-Object id -eq 'audit.context').status|Should -Be 'pass'
            $script:contextArguments[0][3]|Should -BeExactly $firstSubscription
            $script:urls.Count|Should -BeGreaterThan 0
            @($script:urls|Where-Object{$_ -notlike "*/subscriptions/$firstSubscription/*"}).Count|Should -Be 0
            @($script:urls|Where-Object{$_ -notlike '*resourceGroups/fixture-rg/*'}).Count|Should -Be 0
            $script:urls.Clear()
            $secondResult=Invoke-AzdValidationSet -Definitions $second
            ($secondResult|Where-Object id -eq 'audit.context').status|Should -Be 'pass'
            $script:contextArguments[1][3]|Should -BeExactly $secondSubscription
            $script:urls.Count|Should -BeGreaterThan 0
            @($script:urls|Where-Object{$_ -notlike "*/subscriptions/$secondSubscription/*"}).Count|Should -Be 0
            @($script:urls|Where-Object{$_ -notlike '*resourceGroups/later-rg/*'}).Count|Should -Be 0
        }
    }
}
Describe 'Durable bounded bootstrap evidence' {
    BeforeAll {
        . "$root/hooks/AuditOperationalState.ps1"
        function Set-AutomationVariableValue { param($SubscriptionId,$ResourceGroupName,$AutomationAccountName,$VariableName,$Value) throw 'Unexpected native variable write' }
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile("$root/runbooks/Enable-AdvancedAuditing.ps1",[ref]$tokens,[ref]$errors)
        $function=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-AuditRetentionSetupSignal'},$true)
        . ([scriptblock]::Create($function.Extent.Text))
        $script:id='/subscriptions/cccccccc-cccc-cccc-cccc-cccccccccccc/resourceGroups/fixture-rg/providers/Microsoft.Automation/automationAccounts/fixture-audit'
        $script:now=[DateTimeOffset]'2026-10-10T00:00:00Z'
    }
    It 'projects <SetupState> to <Expected> without asserting actual retention' -ForEach @(
        @{SetupState='setupVerified';Expected='bootstrapVerified'},@{SetupState='setupUnavailable';Expected='degraded'},@{SetupState='setupFailed';Expected='degraded'}
    ) {
        $raw=New-AuditRetentionSetupState -SetupState $SetupState -AccountId $id -ObservedAt $now
        $signal=ConvertTo-AuditRetentionSetupSignal -RawState $raw -Now $now|ConvertFrom-Json
        $signal.status|Should -Be $Expected
        $signal.evidenceScope|Should -Be 'bootstrapOnly'
        $signal.accountId|Should -BeExactly $id
    }
    It 'retains a well-shaped foreign account ID so the diagnostic boundary can refuse its healthy bootstrap claim' {
        $foreign=$id.Replace('fixture-audit','foreign-audit')
        $raw=New-AuditRetentionSetupState -SetupState setupVerified -AccountId $foreign -ObservedAt $now
        $signal=ConvertTo-AuditRetentionSetupSignal -RawState $raw -Now $now|ConvertFrom-Json -DateKind String
        $signal.accountId|Should -BeExactly $foreign
        $signal.accountId|Should -Not -Be $id
        $signal.evidenceScope|Should -Be 'bootstrapOnly'
        # This pure decoder has no emitting-account context. It must preserve
        # provenance rather than stripping it and producing an unbound signal.
    }
    It 'distinguishes stale bootstrap from current degradation' {
        $raw=New-AuditRetentionSetupState -SetupState setupVerified -AccountId $id -ObservedAt $now.AddDays(-8)
        (ConvertTo-AuditRetentionSetupSignal -RawState $raw -Now $now|ConvertFrom-Json).status|Should -Be 'stale'
    }
    It 'treats missing malformed foreign future or arbitrary secret state as unknown' {
        foreach($raw in @($null,'bad SECRET-SENTINEL','{}',(New-AuditRetentionSetupState -SetupState setupVerified -AccountId $id -ObservedAt $now.AddHours(1)),('{"kind":"SECRET-SENTINEL","secret":"Bearer fixture"}'))){
            $signal=ConvertTo-AuditRetentionSetupSignal -RawState $raw -Now $now
            ($signal|ConvertFrom-Json).status|Should -Be 'unknown'
            ($signal|ConvertFrom-Json).accountId|Should -BeNullOrEmpty
            $signal|Should -Not -Match 'SECRET-SENTINEL|Bearer fixture'
        }
    }
    It 'makes disabled state persistence a zero-write operation' {
        function Set-AutomationVariableValue {throw 'Unexpected write'}
        {Save-AuditRetentionSetupState -Enabled $false -SetupState setupUnavailable}|Should -Not -Throw
    }
    It 'persists only bounded scalar state to the exact owned variable' {
        Mock Set-AutomationVariableValue {}
        Save-AuditRetentionSetupState -Enabled $true -SetupState setupUnavailable -SubscriptionId 'cccccccc-cccc-cccc-cccc-cccccccccccc' -ResourceGroupName fixture-rg -AutomationAccountName fixture-audit
        Should -Invoke Set-AutomationVariableValue -Times 1 -Exactly -ParameterFilter {$VariableName -eq 'AuditRetentionSetupState' -and ($Value|ConvertFrom-Json).accountId -eq $script:id -and ($Value|ConvertFrom-Json).setupState -eq 'setupUnavailable'}
    }
}

AfterAll {
    foreach($name in @('az','Invoke-WebRequest','Invoke-RestMethod','Connect-ExchangeOnline','Connect-IPPSSession','Connect-MgGraph','Connect-AzAccount')){Remove-Item ('Function:global:'+$name) -ErrorAction SilentlyContinue}
}
