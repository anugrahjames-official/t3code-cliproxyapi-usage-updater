[CmdletBinding()]
param(
  [switch]$Remove,
  [switch]$Status,
  [ValidateSet('Automatic', 'Startup')][string]$Mode = 'Automatic'
)
$ErrorActionPreference = 'Stop'
$taskName = 'T3 Hub Usage Auto Updater'
$startupTaskName = 'T3 Hub Usage Startup Updater'
$legacyTaskName = 'T3 Grok Hub Usage Auto Updater'
$description = 'T3HUBUSAGEUPDATER:v1 - reapply the local Grok and Antigravity pooled usage adapter after updates; never closes T3.'
$legacyDescription = 'T3GROKHUBUPDATER:v1 - reapply the local Grok and Antigravity pooled usage adapter after updates; never closes T3.'
$taskRunner = Join-Path $PSScriptRoot 'Scheduled-T3HubUsage.vbs'

if ($Status) {
  $task = Get-ScheduledTask -TaskName $taskName, $startupTaskName -ErrorAction SilentlyContinue
  if (-not $task) { $task = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue }
  if ($task) {
    Get-ScheduledTaskInfo -TaskName $task.TaskName | Select-Object TaskName, LastRunTime, LastTaskResult, NextRunTime
  } else {
    Write-Output 'Automatic updater is not installed.'
  }
  return
}

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$startup = Get-ScheduledTask -TaskName $startupTaskName -ErrorAction SilentlyContinue
$legacy = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
if ($Remove) {
  if (-not $existing -and -not $startup -and -not $legacy) {
    Write-Output 'Automatic updater was not installed.'
    return
  }
  foreach ($task in @($existing, $startup, $legacy) | Where-Object { $_ }) {
    if (($task.TaskName -eq $taskName -and $task.Description -ne $description) -or
        ($task.TaskName -eq $startupTaskName -and $task.Description -ne $description) -or
        ($task.TaskName -eq $legacyTaskName -and $task.Description -ne $legacyDescription)) {
      throw "Refusing to remove a task not created by this updater: $($task.TaskName)"
    }
    Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
  }
  Write-Output 'Automatic updater removed.'
  return
}

if (-not (Test-Path -LiteralPath $taskRunner)) { throw "Hidden task runner is missing: $taskRunner" }
if ($Mode -eq 'Automatic' -and $existing -and $existing.Description -ne $description) {
  throw "A different scheduled task already uses this name: $taskName"
}
if ($Mode -eq 'Startup' -and $startup -and $startup.Description -ne $description) {
  throw "A different scheduled task already uses this name: $startupTaskName"
}
if ($Mode -eq 'Startup' -and $existing -and $existing.Description -ne $description) {
  throw "A different scheduled task already uses this name: $taskName"
}
if ($Mode -eq 'Automatic' -and $startup -and $startup.Description -ne $description) {
  throw "A different scheduled task already uses this name: $startupTaskName"
}
if ($legacy -and $legacy.Description -ne $legacyDescription) {
  throw "A different scheduled task already uses the legacy name: $legacyTaskName"
}

$windowsScriptHost = Join-Path $env:WINDIR 'System32\wscript.exe'
$arguments = '//B //NoLogo "' + $taskRunner + '"'
$action = New-ScheduledTaskAction -Execute $windowsScriptHost -Argument $arguments
$logon = New-ScheduledTaskTrigger -AtLogOn -User ($env:USERDOMAIN + '\' + $env:USERNAME)
$principal = New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN + '\' + $env:USERNAME) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

$selectedTask = if ($Mode -eq 'Startup') { $startupTaskName } else { $taskName }
$triggers = if ($Mode -eq 'Startup') { @($logon) } else {
  $poll = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
  @($logon, $poll)
}
Register-ScheduledTask -TaskName $selectedTask -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description $description -Force | Out-Null
if ($legacy) { Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false }
$oppositeTask = if ($Mode -eq 'Startup') { $existing } else { $startup }
if ($oppositeTask) { Unregister-ScheduledTask -TaskName $oppositeTask.TaskName -Confirm:$false }
Start-ScheduledTask -TaskName $selectedTask
if ($Mode -eq 'Startup') {
  Write-Output 'Startup updater enabled. It runs hidden at logon, skips while T3 is running, and logs results.'
} else {
  Write-Output 'Automatic updater enabled. It runs hidden at logon and every 5 minutes, skips while T3 is running, and logs results.'
}
