#Requires -Version 7.6
function New-AuditRetentionSetupState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('setupVerified','setupUnavailable','setupFailed')][string]$SetupState,
        [Parameter(Mandatory)][string]$AccountId,
        [DateTimeOffset]$ObservedAt = [DateTimeOffset]::UtcNow
    )
    if ($AccountId -notmatch '^/subscriptions/[a-f0-9-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft.Automation/automationAccounts/[A-Za-z0-9_-]+$') { throw 'Invalid operational-state target.' }
    [ordered]@{kind='advancedAuditing.retentionSetup';schemaVersion='1.0';accountId=$AccountId;observedAt=$ObservedAt.ToUniversalTime().ToString('o');setupState=$SetupState} | ConvertTo-Json -Compress
}

function Save-AuditRetentionSetupState {
    [CmdletBinding()]
    param([bool]$Enabled, [string]$SetupState, [string]$SubscriptionId, [string]$TenantId, [string]$ResourceGroupName, [string]$AutomationAccountName, $HookContext)
    if (-not $Enabled) { return }
    $id='/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}' -f $SubscriptionId,$ResourceGroupName,$AutomationAccountName
    $value=New-AuditRetentionSetupState -SetupState $SetupState -AccountId $id
    try {
        Set-AutomationVariableValue -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -VariableName 'AuditRetentionSetupState' -Value $value -HookContext $HookContext
    } catch {
        if (Test-AuditOperatorContextException -ErrorRecord $_) { throw }
        throw 'Could not persist optional retention-setup evidence. No current retention readiness is established.'
    }
}
