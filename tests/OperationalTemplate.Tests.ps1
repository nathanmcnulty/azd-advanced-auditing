#Requires -Version 7.6
Describe 'Actual compiled optional monitoring resources' {
    BeforeAll {
        $root=Split-Path $PSScriptRoot -Parent
        $binary=$env:AUD_BICEP_PATH
        if(-not $binary){$binary=Join-Path $HOME $(if($IsWindows){'.azure/bin/bicep.exe'}else{'.azure/bin/bicep'})}
        $version=& $binary --version
        if($LASTEXITCODE -or $version -notmatch '0\.46\.1 '){throw 'Exact registered Bicep 0.46.1 binary required.'}
        $compiled=& $binary build (Join-Path $root 'infra/main.bicep') --stdout
        if($LASTEXITCODE){throw 'Actual production Bicep compilation failed.'}
        $script:template=($compiled -join "`n")|ConvertFrom-Json -DateKind String -Depth 100
        $script:optional=@($template.resources|Where-Object{$_.PSObject.Properties['condition']})
    }
    It 'compiles exactly four optional resources behind the false default, without roles or recipients' {
        $template.parameters.operationalAlertsEnabled.defaultValue|Should -BeFalse
        $extra=@($optional|Where-Object{$_.condition -eq "[parameters('operationalAlertsEnabled')]"})
        $extra.Count|Should -Be 4
        @($extra|Where-Object type -eq 'Microsoft.Automation/automationAccounts/variables').Count|Should -Be 1
        @($extra|Where-Object type -eq 'Microsoft.Insights/diagnosticSettings').Count|Should -Be 1
        @($extra|Where-Object type -eq 'Microsoft.Resources/deployments').Count|Should -Be 2
        @($template.resources|Where-Object type -eq 'Microsoft.Authorization/roleAssignments').Count|Should -Be 0
        @($template.resources|Where-Object type -eq 'Microsoft.Insights/actionGroups').Count|Should -Be 0
    }
    It 'embeds exact solution-owned KQL and existing selected workspace/action group only' {
        $alerts=@($optional|Where-Object type -eq 'Microsoft.Resources/deployments')
        foreach($alert in $alerts){
            $child=@($alert.properties.template.resources)
            $child.Count|Should -Be 1
            $child[0].type|Should -Be 'Microsoft.Insights/scheduledQueryRules'
            $alert.properties.parameters.workspaceResourceId.value|Should -Be "[parameters('operationalWorkspaceResourceId')]"
            $alert.properties.parameters.actionGroupResourceId.value|Should -Be "[parameters('operationalActionGroupResourceId')]"
            $alert.properties.parameters.windowSize.value|Should -Be 'PT30M'
            $alert.properties.template.parameters.evaluationFrequency.defaultValue|Should -Be 'PT5M'
            $child[0].properties.evaluationFrequency|Should -Be "[parameters('evaluationFrequency')]"
            $alert.properties.parameters.autoMitigate.value|Should -BeFalse
            $expression=$alert.properties.parameters.query.value
            $expression|Should -Match 'replace\(variables'
            $variableName=[regex]::Match($expression, "variables\('([^']+)'\)").Groups[1].Value
            $embedded=$template.variables.PSObject.Properties[$variableName].Value
            $embedded|Should -Match '_ResourceId =~'
            $embedded|Should -BeIn @((Get-Content "$root/infra/queries/failed-jobs.kql" -Raw),(Get-Content "$root/infra/queries/retention-setup.kql" -Raw))
            if($embedded -match 'advancedAuditing.retentionSetup'){
                $binding='| extend status = iff(isnotempty(tostring(signal.accountId)) and tolower(tostring(signal.accountId)) == tolower(_ResourceId), tostring(signal.status), "unknown")'
                $embedded|Should -Match ([regex]::Escape($binding))
                $embedded.IndexOf($binding)|Should -BeLessThan $embedded.IndexOf('| where status in')
                $embedded|Should -Not -Match '\| where tostring\(signal.status\)'
            }
            $alert.properties.parameters.query.value|Should -Match 'Microsoft.Automation/automationAccounts'
        }
        $kql=Get-Content "$root/infra/queries/retention-setup.kql" -Raw
        $kql|Should -Match 'parse_json\(ResultDescription\)'
        $kql|Should -Match 'StreamType_s == "Output"'
        $kql|Should -Match 'bootstrap|advancedAuditing.retentionSetup'
        $kql|Should -Not -Match 'Caller_s|Recipient|Email|Secret'
    }
    It 'hash-locks all immutable copies and leaves audit remediation/schedule parameters unchanged' {
        $lock=Get-Content "$root/azd-components.lock.json" -Raw|ConvertFrom-Json
        foreach($component in $lock.components){
            $expectedRevision=if($component.id -eq 'azure-monitor-scheduled-query-notifications'){'2948cdbaf9497b69dd7b288b028b6b84dc2fb23b'}else{'6dc5841a3156b904b89f0f4ff8d97207a26ec15a'}
            $component.sourceRevision|Should -Be $expectedRevision
            foreach($file in $component.files){(Get-FileHash (Join-Path $root $file.target)).Hash.ToLowerInvariant()|Should -Be $file.sha256}
        }
        $template.parameters.scheduleStartOffset.defaultValue|Should -Be 'PT15M'
        $template.parameters.enableResourceLock.defaultValue|Should -BeTrue
        ($template.resources|Where-Object type -eq 'Microsoft.Automation/automationAccounts/schedules').properties.frequency|Should -Be 'Day'
        (Get-Content "$root/infra/main.parameters.json" -Raw|ConvertFrom-Json).parameters.operationalAlertsEnabled.value|Should -BeFalse
    }
}
