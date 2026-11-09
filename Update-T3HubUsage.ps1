[CmdletBinding()]
param(
  [switch]$Auto,
  [switch]$Headless,
  [switch]$Rollback,
  [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$stateRoot = Join-Path $env:LOCALAPPDATA 't3code-hub-usage-updater'
$backupRoot = Join-Path $stateRoot 'backups'
$logRoot = Join-Path $stateRoot 'logs'
$lastEventPath = Join-Path $stateRoot 'last-auto-event.txt'
$mutexName = 'Local\T3HubUsageUpdater-' + $env:USERNAME
New-Item -ItemType Directory -Force -Path $stateRoot, $backupRoot, $logRoot | Out-Null
$logPath = Join-Path $logRoot ('updater-' + (Get-Date -Format 'yyyyMMdd') + '.log')

function Write-Event([string]$Message) {
  if (($Auto -or $Headless) -and (Test-Path -LiteralPath $lastEventPath)) {
    $previous = [IO.File]::ReadAllText($lastEventPath, [Text.Encoding]::UTF8)
    if ($previous -eq $Message) { return }
  }
  if ($Auto -or $Headless) {
    [IO.File]::WriteAllText($lastEventPath, $Message, (New-Object Text.UTF8Encoding($false)))
  }
  Add-Content -LiteralPath $logPath -Value ((Get-Date -Format o) + ' ' + $Message) -Encoding UTF8
  if (-not ($Auto -or $Headless)) { Write-Host $Message }
}

function Test-PathInside([string]$Child, [string]$Parent) {
  if ([string]::IsNullOrWhiteSpace($Child) -or [string]::IsNullOrWhiteSpace($Parent)) { return $false }
  $base = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath($Child)
  return $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-T3InstallRoot {
  if ($InstallRoot) {
    $candidate = [IO.Path]::GetFullPath($InstallRoot)
    if (Test-Path -LiteralPath (Join-Path $candidate 'resources\server.asar')) { return $candidate }
    throw "The supplied T3 install root does not contain resources\server.asar: $candidate"
  }

  $processRoots = @()
  try {
    $processes = Get-CimInstance -ClassName Win32_Process -ErrorAction Stop
    foreach ($process in $processes) {
      if ($process.Name -like 'T3 Code*.exe' -and $process.ExecutablePath) {
        $processRoots += Split-Path -Parent $process.ExecutablePath
      }
    }
  } catch {
    throw "Could not inspect running processes safely: $($_.Exception.Message)"
  }
  $uniqueRoots = @($processRoots | Sort-Object -Unique)
  if ($uniqueRoots.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $uniqueRoots[0] 'resources\server.asar'))) {
    return $uniqueRoots[0]
  }
  if ($uniqueRoots.Count -gt 1) {
    throw 'More than one T3 installation is running. Close the other installation or pass -InstallRoot.'
  }

  $default = Join-Path $env:LOCALAPPDATA 'Programs\t3code'
  if (Test-Path -LiteralPath (Join-Path $default 'resources\server.asar')) { return $default }

  $registryRoots = @()
  $uninstallRoots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  foreach ($key in $uninstallRoots) {
    foreach ($item in (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
      if ($item.DisplayName -match '^T3 Code' -and $item.InstallLocation) {
        $registryRoots += $item.InstallLocation
      }
    }
  }
  $valid = @($registryRoots | Sort-Object -Unique | Where-Object {
    Test-Path -LiteralPath (Join-Path $_ 'resources\server.asar')
  })
  if ($valid.Count -eq 1) { return [IO.Path]::GetFullPath($valid[0]) }
  throw 'Could not uniquely locate T3 Code. Pass -InstallRoot to choose the installation.'
}

function Get-NodePath {
  $candidates = @()
  if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'nodejs\node.exe' }
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($command) { $candidates += $command.Source }
  $candidates += Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'
  foreach ($candidate in ($candidates | Where-Object { $_ } | Sort-Object -Unique)) {
    if (Test-Path -LiteralPath $candidate) {
      $versionText = (& $candidate --version 2>$null | Select-Object -First 1)
      if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '^v(\d+)\.(\d+)\.') { continue }
      $major = [int]$Matches[1]
      $minor = [int]$Matches[2]
      if ($major -gt 22 -or ($major -eq 22 -and $minor -ge 12)) { return $candidate }
    }
  }
  throw 'Node.js 22.12 or newer is required. Install Node.js, then rerun the updater.'
}

function Get-T3Processes([string]$Root) {
  $roots = @(
    [IO.Path]::GetFullPath($Root),
    (Join-Path $env:LOCALAPPDATA 't3code-updater')
  )
  $found = @()
  try {
    $all = Get-CimInstance -ClassName Win32_Process -ErrorAction Stop
  } catch {
    throw "Could not inspect T3 processes safely: $($_.Exception.Message)"
  }
  foreach ($process in $all) {
    $isT3Name = $process.Name -like 'T3 Code*.exe'
    $inside = $false
    foreach ($rootPath in $roots) {
      if ($process.ExecutablePath -and (Test-PathInside $process.ExecutablePath $rootPath)) {
        $inside = $true
        break
      }
    }
    if ($isT3Name -or $inside) { $found += $process }
  }
  return $found
}

function Wait-ForT3Exit([string]$Root) {
  $lastNotice = [DateTime]::MinValue
  while ($true) {
    $active = @(Get-T3Processes $Root)
    if ($active.Count -eq 0) {
      Start-Sleep -Seconds 3
      if (@(Get-T3Processes $Root).Count -eq 0) { return $true }
    }
    if ($Auto -or $Headless) {
      Write-Event 'T3 Code or its updater is running; automatic patch deferred until the next closed-app check.'
      return $false
    }
    if ((Get-Date) - $lastNotice -gt [TimeSpan]::FromSeconds(15)) {
      $names = (($active | Select-Object -ExpandProperty Name -Unique) -join ', ')
      Write-Host "Waiting for T3 Code to close normally ($names). This updater will not close it."
      $lastNotice = Get-Date
    }
    Start-Sleep -Seconds 5
  }
}

function Invoke-Patcher([string]$Node, [string[]]$Arguments) {
  $output = @(& $Node (Join-Path $scriptRoot 'patcher.mjs') @Arguments 2>&1)
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    throw "Archive patcher failed: $($output -join [Environment]::NewLine)"
  }
  $jsonLine = $output | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith('{') } | Select-Object -Last 1
  if (-not $jsonLine) { throw "Archive patcher returned no status document: $($output -join [Environment]::NewLine)" }
  return ($jsonLine | ConvertFrom-Json)
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Save-AtomicJson([string]$Path, $Value) {
  $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  $json = $Value | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Invoke-Rollback([string]$Root) {
  $statePath = Join-Path $stateRoot 'last-install.json'
  if (-not (Test-Path -LiteralPath $statePath)) { throw 'No updater backup record exists; there is nothing to roll back.' }
  $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $target = Join-Path $Root 'resources\server.asar'
  if ([IO.Path]::GetFullPath($state.archive) -ne [IO.Path]::GetFullPath($target)) {
    throw 'The saved backup belongs to a different T3 installation.'
  }
  if (-not (Test-Path -LiteralPath $state.backup)) { throw 'The recorded original archive backup is missing.' }
  $currentHash = Get-Sha256 $target
  if ($currentHash -ne $state.patchedSha256) {
    throw 'The installed archive changed after patching; refusing to restore a stale backup over it.'
  }
  if ((Get-Sha256 $state.backup) -ne $state.originalSha256) {
    throw 'The saved original archive backup hash does not match its record.'
  }
  $rollbackCopy = Join-Path (Split-Path -Parent $target) ('.server.asar.rollback-' + [guid]::NewGuid().ToString('N'))
  $rollbackCapture = Join-Path $backupRoot ('server.asar.before-rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
  Copy-Item -LiteralPath $state.backup -Destination $rollbackCopy
  if ((Get-Sha256 $rollbackCopy) -ne $state.originalSha256) {
    Remove-Item -LiteralPath $rollbackCopy -Force -ErrorAction SilentlyContinue
    throw 'The rollback copy failed hash verification.'
  }
  [IO.File]::Replace($rollbackCopy, $target, $rollbackCapture)
  if ((Get-Sha256 $target) -ne $state.originalSha256 -or (Get-Sha256 $rollbackCapture) -ne $currentHash) {
    throw "Rollback verification failed. Preserved the pre-rollback archive at $rollbackCapture"
  }
  Write-Event "Restored the original T3 server archive. Patched archive saved at $rollbackCapture."
}

$mutex = $null
$ownsMutex = $false
$exitCode = 0
try {
  $mutex = [System.Threading.Mutex]::new($false, $mutexName)
  try { $ownsMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
  if (-not $ownsMutex) {
    Write-Event 'Another updater instance is running; this invocation was skipped.'
  } else {
    $root = Resolve-T3InstallRoot
    $resources = Join-Path $root 'resources'
    $archive = Join-Path $resources 'server.asar'
    if (-not (Test-Path -LiteralPath $archive)) { throw "T3 server archive not found: $archive" }

    if (-not (Wait-ForT3Exit $root)) {
      # Automatic mode never waits or closes T3.
    } elseif ($Rollback) {
      Invoke-Rollback $root
    } else {
      $node = Get-NodePath
      $inspection = Invoke-Patcher -Node $node -Arguments @('inspect', $archive)
      if ($inspection.status -eq 'already-present') {
        Write-Event "Grok and Antigravity usage logic is already present; no archive change was made. $($inspection.reason)"
      } elseif ($inspection.status -notin @('unpatched', 'needs-antigravity', 'needs-antigravity-model-allowlist')) {
        throw "Unexpected archive inspection status: $($inspection.status)"
      } else {
        $completed = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
          $sourceHash = Get-Sha256 $archive
          $work = Join-Path $stateRoot ('work-' + [guid]::NewGuid().ToString('N'))
          New-Item -ItemType Directory -Path $work -Force | Out-Null
          try {
            $prepared = Invoke-Patcher -Node $node -Arguments @('build', $archive, $work)
            if ($prepared.status -eq 'already-present') {
              Write-Event "Grok and Antigravity usage logic appeared during the update; no archive change was made. $($prepared.reason)"
              $completed = $true
              break
            }
            if ($prepared.status -ne 'prepared') { throw "Unexpected build status: $($prepared.status)" }
            if ((Get-Sha256 $archive) -ne $sourceHash -or $prepared.sourceHash -ne $sourceHash) {
              Write-Event "T3 updated server.asar during build attempt $attempt; rebuilding from the new installed version."
              continue
            }
            if (@(Get-T3Processes $root).Count -gt 0) {
              if ($Auto -or $Headless) {
                Write-Event 'T3 Code reopened during the build; automatic patch deferred until the next closed-app check.'
                $completed = $true
                break
              }
              if (-not (Wait-ForT3Exit $root)) {
                $completed = $true
                break
              }
              if ((Get-Sha256 $archive) -ne $sourceHash) {
                Write-Event 'T3 updated server.asar while waiting; rebuilding from the new installed version.'
                continue
              }
            }

            $stagedInResources = Join-Path $resources ('.server.asar.grok-next-' + [guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $prepared.outputArchive -Destination $stagedInResources
            if ((Get-Sha256 $stagedInResources) -ne $prepared.patchedHash) {
              Remove-Item -LiteralPath $stagedInResources -Force -ErrorAction SilentlyContinue
              throw 'The same-directory staging copy failed hash verification.'
            }
            if (@(Get-T3Processes $root).Count -gt 0) {
              Remove-Item -LiteralPath $stagedInResources -Force -ErrorAction SilentlyContinue
              if ($Auto -or $Headless) {
                Write-Event 'T3 Code reopened before replacement; automatic patch deferred until the next closed-app check.'
                $completed = $true
                break
              }
              if (-not (Wait-ForT3Exit $root)) { $completed = $true; break }
              if ((Get-Sha256 $archive) -ne $sourceHash) {
                Write-Event 'T3 updated server.asar before replacement; rebuilding from the new installed version.'
                continue
              }
              $stagedInResources = Join-Path $resources ('.server.asar.grok-next-' + [guid]::NewGuid().ToString('N'))
              Copy-Item -LiteralPath $prepared.outputArchive -Destination $stagedInResources
            }
            if ((Get-Sha256 $archive) -ne $sourceHash) {
              Remove-Item -LiteralPath $stagedInResources -Force -ErrorAction SilentlyContinue
              Write-Event 'T3 updated server.asar before replacement; rebuilding from the new installed version.'
              continue
            }

            $backup = Join-Path $backupRoot ('server.asar.original-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
            if ([IO.Path]::GetPathRoot($backup) -ne [IO.Path]::GetPathRoot($archive)) {
              Remove-Item -LiteralPath $stagedInResources -Force -ErrorAction SilentlyContinue
              throw 'Backup and T3 install are on different volumes; refusing a non-atomic replacement.'
            }
            [IO.File]::Replace($stagedInResources, $archive, $backup)
            $installedHash = Get-Sha256 $archive
            $savedOriginalHash = Get-Sha256 $backup
            if ($installedHash -ne $prepared.patchedHash -or $savedOriginalHash -ne $sourceHash) {
              $recovery = Join-Path $backupRoot ('recovery-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
              if ((Test-Path -LiteralPath $backup) -and $savedOriginalHash -eq $sourceHash) {
                [IO.File]::Replace($backup, $archive, $recovery)
              }
              throw "Replacement hash verification failed. Recovery copy: $recovery"
            }

            $state = [pscustomobject]@{
              version = 1
              installedAt = (Get-Date).ToString('o')
              installRoot = $root
              archive = $archive
              modulePath = $prepared.modulePath
              backup = $backup
              originalSha256 = $sourceHash
              patchedSha256 = $prepared.patchedHash
            }
            Save-AtomicJson (Join-Path $stateRoot 'last-install.json') $state
            Write-Event "Grok and Antigravity Hub usage patch applied to the installed T3 build. Original backup: $backup. Reopen T3 to load it."
            $completed = $true
            break
          } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
          }
        }
        if (-not $completed) {
          throw 'T3 bundle kept changing during three attempts. No patch was installed.'
        }
      }
    }
  }
} catch {
  Write-Event ("FAILED: " + $_.Exception.Message)
  $exitCode = 1
} finally {
  if ($ownsMutex -and $mutex) {
    try { $mutex.ReleaseMutex() } catch {}
  }
  if ($mutex) { $mutex.Dispose() }
}
exit $exitCode
