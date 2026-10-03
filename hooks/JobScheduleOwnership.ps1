function Test-AuditGuid {
  param([string]$Value)
  $parsed = [guid]::Empty
  return [guid]::TryParse($Value, [ref]$parsed)
}

function Assert-AuditOwnershipReceiptTarget {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedAccountId,
    [Parameter(Mandatory = $true)][string]$ExpectedPrincipalId,
    [Parameter(Mandatory = $true)][string]$ExpectedJobScheduleId,
    [Parameter(Mandatory = $true)]$Account,
    [Parameter(Mandatory = $true)]$JobSchedule
  )
  $liveJobScheduleId = [string]$JobSchedule.properties.jobScheduleId
  if ([string]::IsNullOrWhiteSpace($liveJobScheduleId)) { $liveJobScheduleId = [string]$JobSchedule.name }
  if (-not (Test-AuditGuid -Value $ExpectedJobScheduleId) -or
      [string]$Account.id -ine $ExpectedAccountId -or
      [string]$Account.identity.principalId -ine $ExpectedPrincipalId -or
      $liveJobScheduleId -ine $ExpectedJobScheduleId -or
      [string]$JobSchedule.properties.schedule.name -ine 'advanced-auditing-daily' -or
      [string]$JobSchedule.properties.runbook.name -ine 'Enable-AdvancedAuditing') {
    throw 'Provisioned Automation account or jobSchedule does not match the template ownership receipt.'
  }
}

function Resolve-AuditJobScheduleOwnership {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedAccountId,
    [AllowNull()]$Account,
    [AllowNull()][object[]]$JobSchedules = @(),
    [string]$ReceiptAccountId = '',
    [string]$ReceiptPrincipalId = '',
    [string]$ReceiptJobScheduleId = '',
    [string]$AdoptAccountId = '',
    [string]$AdoptPrincipalId = '',
    [string]$AdoptJobScheduleId = ''
  )

  if ($null -eq $Account) {
    return [pscustomobject]@{ JobScheduleId = [guid]::NewGuid().ToString(); OwnedJobScheduleId = '' }
  }

  $liveAccountId = [string]$Account.id
  $livePrincipalId = [string]$Account.identity.principalId
  if ($liveAccountId -ine $ExpectedAccountId -or [string]::IsNullOrWhiteSpace($livePrincipalId)) {
    throw 'The live Automation account identity does not match the expected deployment target.'
  }

  $hasReceipt = -not [string]::IsNullOrWhiteSpace($ReceiptAccountId)
  $receiptParts = @(@($ReceiptAccountId, $ReceiptPrincipalId, $ReceiptJobScheduleId) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($receiptParts.Count -gt 0 -and $receiptParts.Count -lt 3) {
    throw 'The saved Automation ownership receipt is incomplete.'
  }
  if ($hasReceipt) {
    if ($ReceiptAccountId -ine $liveAccountId -or $ReceiptPrincipalId -ine $livePrincipalId -or
        -not (Test-AuditGuid -Value $ReceiptJobScheduleId)) {
      throw 'The saved Automation ownership receipt does not match the live account identity or has no valid jobSchedule ID.'
    }
    $selectedId = $ReceiptJobScheduleId
  }
  else {
    if ($AdoptAccountId -ine $liveAccountId -or $AdoptPrincipalId -ine $livePrincipalId) {
      throw 'Existing Automation account has no matching ownership receipt. Explicit adoption of its account ID and principal ID is required before redeployment.'
    }
    $selectedId = $AdoptJobScheduleId
  }

  $owned = @()
  foreach ($jobSchedule in @($JobSchedules)) {
    if ($null -eq $jobSchedule) { continue }
    $id = [string]$jobSchedule.properties.jobScheduleId
    $nameId = [string]$jobSchedule.name
    if ([string]::IsNullOrWhiteSpace($id)) { $id = $nameId }
    if (-not [string]::IsNullOrWhiteSpace($nameId) -and $nameId -ine $id) {
      throw 'A live jobSchedule has inconsistent name and jobScheduleId values.'
    }
    if (-not (Test-AuditGuid -Value $id)) {
      throw 'A live jobSchedule has no valid GUID. Refusing to change an ambiguous account.'
    }
    $scheduleName = [string]$jobSchedule.properties.schedule.name
    $runbookName = [string]$jobSchedule.properties.runbook.name
    if ($scheduleName -ieq 'advanced-auditing-daily' -and $runbookName -ine 'Enable-AdvancedAuditing') {
      throw 'The template schedule name is linked to an unexpected runbook.'
    }
    if ($id -ieq $selectedId -and ($scheduleName -ine 'advanced-auditing-daily' -or $runbookName -ine 'Enable-AdvancedAuditing')) {
      throw 'The recorded jobSchedule ID now belongs to a different schedule or runbook.'
    }
    if ($scheduleName -ieq 'advanced-auditing-daily' -and $runbookName -ieq 'Enable-AdvancedAuditing') {
      $owned += $id
    }
  }

  if ($owned.Count -gt 1) { throw 'More than one live template jobSchedule exists; explicit reconciliation is required.' }
  if ($owned.Count -eq 1 -and [string]::IsNullOrWhiteSpace($selectedId)) {
    throw 'A live template jobSchedule requires its exact ID for explicit adoption.'
  }
  if ($owned.Count -eq 1 -and $owned[0] -ine $selectedId) {
    throw 'The live template jobSchedule ID differs from the saved receipt or explicit adoption ID.'
  }
  if (-not [string]::IsNullOrWhiteSpace($selectedId) -and -not (Test-AuditGuid -Value $selectedId)) {
    throw 'The adopted jobSchedule ID must be a GUID.'
  }
  if ($owned.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($AdoptJobScheduleId) -and -not $hasReceipt) {
    throw 'The explicit adoption jobSchedule ID was not found in the live account.'
  }

  return [pscustomobject]@{
    JobScheduleId = if ([string]::IsNullOrWhiteSpace($selectedId)) { [guid]::NewGuid().ToString() } else { $selectedId }
    OwnedJobScheduleId = if ($owned.Count -eq 1) { $owned[0] } else { '' }
  }
}
