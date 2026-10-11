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
            $script:foreign=$false;$script:mismatch=$false
            $script:urls=[Collections.Generic.List[string]]::new()
            Mock az {
                $global:LASTEXITCODE=0
                if($args[0] -eq 'account'){
                    $sub=if($script:mismatch){'foreign'}else{$script:t.subscriptionId}
                    return (@{id=$sub;tenantId=$t.tenantId;user=@{name=$t.account;type='user'}}|ConvertTo-Json -Compress)
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
        It 'stops all ARM reads on wrong cached context' {
            $script:mismatch=$true
            $r=Invoke-AuditDeploymentValidation -Target $t
            ($r.checks|Where-Object id -eq 'audit.context').status|Should -Be 'fail'
            Should -Invoke az -Times 1 -Exactly
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
            $first=@(New-AuditValidationDefinitions $t)
            $t.resourceGroup='later-rg'
            $second=@(New-AuditValidationDefinitions $t)
            $null=Invoke-AzdValidationSet -Definitions $first
            @($script:urls|Where-Object{$_ -notlike '*resourceGroups/fixture-rg/*'}).Count|Should -Be 0
            $script:urls.Clear()
            $null=Invoke-AzdValidationSet -Definitions $second
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
