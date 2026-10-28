param(
    [switch]$Force,
    [switch]$DryRun,
    [switch]$IncludeForeign
)

$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'Stop Qing services'

. (Join-Path $PSScriptRoot '_config.ps1')

$Node = $QingConfig.Node

$Targets = @(
    [pscustomobject]@{
        Name = 'GPT-SoVITS WebUI'; Port = $QingConfig.WebUIPort; MatchNode = $false
        Regex = '(?i)(^|[\\/\s"])webui\.py($|[\s"])'
    }
    [pscustomobject]@{
        Name = 'GPT-SoVITS inference'; Port = $QingConfig.InferencePort; MatchNode = $false
        Regex = '(?i)(^|[\\/\s"])inference_webui\.py($|[\s"])'
    }
    [pscustomobject]@{
        Name = 'Qing TTS adapter'; Port = $QingConfig.AdapterPort; MatchNode = $false
        Regex = '(?i)(^|[\\/\s"])qing_tts_adapter[^\\/\s"]*\.py($|[\s"])'
    }
    [pscustomobject]@{
        Name = 'SillyTavern'; Port = $QingConfig.STPort; MatchNode = $true
        Regex = '(?i)(^|[\\/\s"])server\.js($|[\s"])'
    }
)

function Say([string]$Message, [string]$Color = 'Gray') {
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
}

function Get-Owner([int]$Port) {
    $conn = $null
    try {
        $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Select-Object -First 1
    } catch {
        return $null
    }
    if (-not $conn) { return $null }
    $proc = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$conn.OwningProcess) -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Pid = [int]$conn.OwningProcess
        Name = $(if ($proc) { [string]$proc.Name } else { '?' })
        Path = $(if ($proc) { [string]$proc.ExecutablePath } else { '' })
        CommandLine = $(if ($proc) { [string]$proc.CommandLine } else { '' })
    }
}

function Test-TargetProcess($Proc, $Target) {
    if (-not $Proc -or -not $Proc.CommandLine) { return $false }
    if ($Target.MatchNode) {
        if (-not ($Proc.ExecutablePath -and $Proc.ExecutablePath -ieq $Node)) { return $false }
    }
    return ([string]$Proc.CommandLine -match $Target.Regex)
}

function Stop-ProcessTree([int]$ProcessId) {
    & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

Clear-Host
Say 'Stopping Qing services on ports 9874 / 9872 / 9880 / 8000' 'Cyan'
if ($DryRun) { Say 'DRY RUN: nothing will be stopped.' 'Magenta' }

$all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)

# 1) The watchdog and any running launcher must die first, otherwise they will
# immediately start the services again while this script is still stopping them.
$guards = @($all | Where-Object {
    $cl = [string]$_.CommandLine
    if (-not $cl -or $_.ProcessId -eq $PID) { return $false }
    return ($cl -match '(?i)watchdog\.ps1' -or
            $cl -match '(?i)start_watchdog\.bat' -or
            $cl -match '(?i)StartQingAll\.ps1' -or
            $cl -match '(?i)start_all\.ps1' -or
            $cl -match '(?i)start_all\.bat')
})
if ($guards.Count -gt 0) {
    Say ('Stopping watchdog / launcher hosts: ' + (($guards | ForEach-Object { $_.ProcessId }) -join ', ')) 'Yellow'
    foreach ($g in $guards) {
        if ($DryRun) {
            Say ('  would stop PID {0} ({1})' -f $g.ProcessId, $g.Name) 'DarkGray'
        } else {
            Stop-ProcessTree $g.ProcessId | Out-Null
        }
    }
} else {
    Say 'No watchdog/launcher process was running.' 'DarkGray'
}

# 2) Stop every process that belongs to a target service, including duplicate
# copies that are not currently listening on the port.
$killed = @{}
foreach ($t in $Targets) {
    $owned = @($all | Where-Object { Test-TargetProcess $_ $t })
    if ($owned.Count -eq 0) {
        Say ('{0}: no matching process (port {1})' -f $t.Name, $t.Port) 'DarkGray'
        continue
    }
    foreach ($p in $owned) {
        $procId = [int]$p.ProcessId
        if ($procId -eq $PID -or $killed.ContainsKey($procId)) { continue }
        Say ('{0}: PID {1} ({2})' -f $t.Name, $procId, $p.Name) 'Yellow'
        if ($DryRun) {
            Say '  would stop this process tree' 'DarkGray'
            continue
        }
        if (Stop-ProcessTree $procId) {
            $killed[$procId] = $t.Name
            Say ('  stopped PID {0}' -f $procId) 'Green'
        } else {
            Say ('  failed to stop PID {0}' -f $procId) 'Red'
        }
    }
}

if (-not $DryRun -and $killed.Count -gt 0) {
    Start-Sleep -Seconds 2
}

# 3) Close leftover console hosts for the service runners.
if (-not $DryRun) {
    $hosts = @($all | Where-Object {
        $cl = [string]$_.CommandLine
        return ($cl -and $_.ProcessId -ne $PID -and
                $cl -match '(?i)Run-(GPTWebUI|Inference|Adapter|SillyTavern)\.ps1')
    })
    foreach ($h in $hosts) {
        if (Stop-ProcessTree $h.ProcessId) {
            Say ('  closed leftover service window PID {0}' -f $h.ProcessId) 'DarkGray'
        }
    }
}

# 4) Verify the four ports.
Write-Host ''
Say 'Port check after stop:' 'Cyan'
$failed = $false
foreach ($t in $Targets) {
    $o = Get-Owner $t.Port
    if (-not $o) {
        Say ('  {0,-22} port {1}: free' -f $t.Name, $t.Port) 'Green'
        continue
    }
    $proc = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $o.Pid) -ErrorAction SilentlyContinue
    $isOurs = Test-TargetProcess $proc $t
    if ($isOurs) { $failed = $true }
    $label = if ($isOurs) { 'still occupied by our service' } else { 'occupied by another program' }
    Say ('  {0,-22} port {1}: {2} (PID {3} {4})' -f $t.Name, $t.Port, $label, $o.Pid, $o.Name) $(if ($isOurs) { 'Red' } else { 'Yellow' })
    if (-not $isOurs -and $IncludeForeign -and -not $DryRun) {
        if (Stop-ProcessTree $o.Pid) {
            Say ('    stopped foreign PID {0} because -IncludeForeign was used' -f $o.Pid) 'Yellow'
        }
    }
}

Write-Host ''
if ($DryRun) {
    Say 'Dry run finished. Run StopQing.bat (or StopQingAll.ps1 -Force) to actually stop.' 'Cyan'
    exit 0
}
if ($failed) {
    Say 'Some Qing services are still listening. Check the PIDs above.' 'Red'
    exit 1
}
Say 'All Qing service ports are free.' 'Green'
Say 'You can check again with Show-Ports / 检查端口占用.bat' 'Cyan'
exit 0
