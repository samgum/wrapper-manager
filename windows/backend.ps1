[CmdletBinding()]
param(
    [ValidateSet('Start','Status','Stop')][string]$Action = 'Start',
    [ValidateSet('whpx','tcg')][string]$Acceleration = 'whpx'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runtime = $PSScriptRoot
$launcher = Join-Path $runtime 'wrapper-manager-qemu.exe'
$stateFile = Join-Path $runtime 'process.json'
$lock = $null
$startedHere = $false

function Stop-OwnedManager($process) {
    & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F | Out-Null
    if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
        throw 'Could not stop the managed backend.'
    }
    Remove-Item -LiteralPath $stateFile -ErrorAction SilentlyContinue
}

function Start-OwnedBackend([string]$Mode) {
    New-Item -ItemType Directory -Force -Path (Join-Path $runtime 'logs') | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $previousLogPrefix = $env:WRAPPER_MANAGER_LOG_PREFIX
    try {
        $env:WRAPPER_MANAGER_LOG_PREFIX = Join-Path $runtime "logs/$stamp"
        $process = Start-Process -FilePath $launcher -ArgumentList @('--host','127.0.0.1','--host-port','12340','--data-dir','data','--accel',$Mode) -WorkingDirectory $runtime -WindowStyle Hidden -PassThru
    } finally {
        if ($null -eq $previousLogPrefix) { Remove-Item Env:WRAPPER_MANAGER_LOG_PREFIX -ErrorAction SilentlyContinue } else { $env:WRAPPER_MANAGER_LOG_PREFIX = $previousLogPrefix }
    }
    [pscustomobject]@{Pid=$process.Id;Started=$process.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
    $script:startedHere = $true
    return $process
}

function Get-OwnedManager {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try {
        $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $process = Get-Process -Id $saved.Pid -ErrorAction Stop
        if ($process.Path -ne $launcher) { return $null }
        $recorded = if ($saved.Started -is [DateTime]) { $saved.Started.ToUniversalTime() } else { [DateTime]::Parse($saved.Started).ToUniversalTime() }
        if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $recorded).TotalSeconds) -gt 1) { return $null }
        return $process
    } catch { return $null }
}

function Get-BackendStatus {
    try {
        $response = Invoke-RestMethod -Uri 'http://127.0.0.1:12340/status' -TimeoutSec 2
        if ($response.code -eq 0 -and $null -ne $response.data.PSObject.Properties['clientCount']) { return $response.data }
    } catch { }
    return $null
}

function Show-BackendStatus($status) {
    Write-Host ('Wrapper Lite manager: http://127.0.0.1:12340 | ready={0} | accounts={1}' -f $status.ready, $status.clientCount)
    $profileFile = Join-Path $runtime 'active-profile.json'
    if (Test-Path -LiteralPath $profileFile) {
        try {
            $profile = Get-Content -LiteralPath $profileFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host ('Active account: {0} | region={1}' -f $profile.label,$profile.region)
        } catch { }
    }
    if ($status.clientCount -eq 0) {
        Write-Host 'First use: open AppleMusicDecrypt v3 and enter login. Enter credentials only in its prompt.'
    }
}

try {
    $lock = [IO.File]::Open((Join-Path $runtime '.control.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $owned = Get-OwnedManager
    if ($Action -eq 'Stop') {
        if (-not $owned) { Write-Host 'This managed backend is stopped.'; exit 0 }
        # Scope shutdown to this exact launcher and its child processes.
        # Never terminate other QEMU instances or WSL distributions.
        Stop-OwnedManager $owned
        Write-Host 'Wrapper Lite stopped. Saved account data remains in Wrapper-Lite/data/data.img.'
        exit 0
    }
    $status = Get-BackendStatus
    if ($status -and $owned -and ($Action -eq 'Status' -or $status.ready)) { Show-BackendStatus $status; exit 0 }
    if ($Action -eq 'Status') { throw 'Backend is not ready. Run the Start entry first.' }
    if ($owned -and -not $status -and ((Get-Date).ToUniversalTime() - $owned.StartTime.ToUniversalTime()).TotalSeconds -ge 120) {
        Write-Host 'Previous backend startup did not respond. Restarting only this managed instance.'
        Stop-OwnedManager $owned
        $owned = $null
    }
    if (-not $owned) {
        $listener = @(Get-NetTCPConnection -State Listen -LocalPort 12340 -ErrorAction SilentlyContinue)
        if ($listener.Count -gt 0) { throw 'Port 12340 is occupied by a different process. No process was stopped.' }
        $owned = Start-OwnedBackend $Acceleration
    }
    Write-Host ('Starting Wrapper Lite manager ({0} mode)...' -f $Acceleration.ToUpper())
    $begin = Get-Date
    $deadline = $begin.AddSeconds(120)
    $nextUpdate = $begin.AddSeconds(5)
    $fallbackUsed = $false
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-OwnedManager)) {
            if ($Acceleration -eq 'whpx' -and -not $fallbackUsed) {
                Write-Host 'Hardware startup exited. Falling back to TCG with saved accounts retained.'
                $Acceleration = 'tcg'
                $owned = Start-OwnedBackend $Acceleration
                $fallbackUsed = $true
                $deadline = (Get-Date).AddSeconds(120)
            } else { throw 'Backend exited. See Wrapper-Lite/logs for details.' }
        }
        $status = Get-BackendStatus
        if ($status -and $status.ready) { Show-BackendStatus $status; exit 0 }
        if (-not $status -and $Acceleration -eq 'whpx' -and -not $fallbackUsed -and ((Get-Date)-$begin).TotalSeconds -ge 20) {
            Write-Host 'Hardware startup is not responding. Falling back to TCG with saved accounts retained.'
            $stalled = Get-OwnedManager
            if ($stalled) { Stop-OwnedManager $stalled }
            $Acceleration = 'tcg'
            $owned = Start-OwnedBackend $Acceleration
            $fallbackUsed = $true
            $deadline = (Get-Date).AddSeconds(120)
        }
        if ((Get-Date) -ge $nextUpdate) {
            $phase = if ($status) { 'restoring saved accounts' } else { 'waiting for Linux HTTP service' }
            Write-Host ('  {0}s: {1}...' -f [int]((Get-Date)-$begin).TotalSeconds,$phase)
            $nextUpdate = (Get-Date).AddSeconds(5)
        }
        Start-Sleep -Seconds 1
    }
    throw 'Backend did not become ready within 120 seconds. See Wrapper-Lite/logs.'
} catch {
    if ($Action -eq 'Start' -and $startedHere) {
        $failed = Get-OwnedManager
        if ($failed) { try { Stop-OwnedManager $failed } catch { } }
    }
    Write-Host ('Error: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($lock) { $lock.Dispose() }
}
