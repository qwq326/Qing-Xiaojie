param(
    [switch]$NoBrowser,
    [switch]$NoPause,
    [switch]$ForceRestart
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot '_config.ps1')

$Root      = $QingConfig.GptSoVITS
$Python    = Join-Path $Root 'runtime\python.exe'
$MainWebUI = Join-Path $Root 'webui.py'
$Inference = Join-Path $Root 'GPT_SoVITS\inference_webui.py'
$Adapter   = $QingConfig.Adapter
$RefAudio  = $QingConfig.RefAudio
$ST        = $QingConfig.SillyTavern
$Node      = $QingConfig.Node
$LogDir    = $QingConfig.LogDir
$Stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$LauncherMutexName = 'QingLauncherStack'
$launcherMutex = $null
$hasLauncherLock = $false

$Services = @(
    [pscustomobject]@{
        Name = 'GPT-SoVITS WebUI'; Port = $QingConfig.WebUIPort; Url = ('http://127.0.0.1:{0}/' -f $QingConfig.WebUIPort)
        Runner = 'Run-GPTWebUI.ps1'; LogName = 'gpt_sovits_main'
        Timeout = 900; Script = $MainWebUI
    }
    [pscustomobject]@{
        Name = 'GPT-SoVITS inference'; Port = $QingConfig.InferencePort; Url = ('http://127.0.0.1:{0}/' -f $QingConfig.InferencePort)
        Runner = 'Run-Inference.ps1'; LogName = 'gpt_sovits_inference'
        Timeout = 1800; Script = $Inference
    }
    [pscustomobject]@{
        Name = 'Qing TTS adapter'; Port = $QingConfig.AdapterPort; Url = ('http://127.0.0.1:{0}/' -f $QingConfig.AdapterPort)
        Runner = 'Run-Adapter.ps1'; LogName = 'qing_tts_adapter'
        Timeout = 300; Script = $Adapter
    }
    [pscustomobject]@{
        Name = 'SillyTavern'; Port = $QingConfig.STPort; Url = ('http://127.0.0.1:{0}/' -f $QingConfig.STPort)
        Runner = 'Run-SillyTavern.ps1'; LogName = 'sillytavern'
        Timeout = 600; Script = (Join-Path $ST 'server.js')
    }
)

function Say([string]$Message, [string]$Color = 'Gray') {
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
}

function Get-LatestServiceLog($Service) {
    if (-not (Test-Path -LiteralPath $LogDir)) { return '' }
    $f = Get-ChildItem -LiteralPath $LogDir -Filter ($Service.LogName + '_*.log') -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
    return ''
}

$script:PortMap = @{}
$script:PortMapAt = [datetime]::MinValue
$script:PortMapValid = $false
$script:ReadyCache = @{}

function Get-PortMap {
    # Get-NetTCPConnection is slow (roughly 0.5-1 s per call) and the launcher
    # needs port ownership many times.  A single netstat snapshot is cached for
    # two seconds; this keeps a "reuse everything" run fast.
    $age = ((Get-Date) - $script:PortMapAt).TotalMilliseconds
    if ($script:PortMap.Count -gt 0 -and $age -lt 2000) { return $script:PortMap }
    $map = @{}
    try {
        $lines = & netstat.exe -ano -p tcp 2>$null
        foreach ($line in $lines) {
            if ($line -match '^\s*TCP(?:v6)?\s+(\S+)\s+\S+\s+LISTENING\s+(\d+)\s*$') {
                $local = [string]$matches[1]
                $ownerPid = [int]$matches[2]
                $idx = $local.LastIndexOf(':')
                if ($idx -lt 0) { continue }
                $portText = $local.Substring($idx + 1)
                if ($portText -notmatch '^\d+$') { continue }
                $p = [int]$portText
                if (-not $map.ContainsKey($p)) {
                    $map[$p] = [pscustomobject]@{
                        Address = $local.Substring(0, $idx)
                        Pid     = $ownerPid
                    }
                }
            }
        }
    } catch { }
    $script:PortMap = $map
    $script:PortMapAt = Get-Date
    $script:PortMapValid = ($map.Count -gt 0)
    return $map
}

function Get-PortOwner([int]$Port) {
    $entry = $null
    $map = Get-PortMap
    if ($map.ContainsKey($Port)) { $entry = $map[$Port] }

    if (-not $entry -and -not $script:PortMapValid) {
        # Fallback only when netstat parsing produced nothing at all
        # (unusual output / localized state names).  A valid map that simply
        # lacks the port means the port is free; don't run the slow cmdlet.
        try {
            $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Select-Object -First 1
            if ($conn) {
                $entry = [pscustomobject]@{
                    Address = [string]$conn.LocalAddress
                    Pid     = [int]$conn.OwningProcess
                }
            }
        } catch { }
    }
    if (-not $entry) { return $null }

    $procId = [int]$entry.Pid
    # Get-Process is fast; the expensive CommandLine lookup is deferred to
    # Test-OwnProcess, which only runs when HTTP/TCP readiness failed.
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    $name = '?'
    $path = ''
    if ($proc) {
        $name = [string]$proc.ProcessName
        $path = [string]$proc.Path
    }
    return [pscustomobject]@{
        Port        = $Port
        Address     = [string]$entry.Address
        Pid         = $procId
        Name        = $name
        Path        = $path
        CommandLine = ''
    }
}

function Test-Ready([string]$Url) {
    # A TCP connect is the right readiness signal here: Gradio and SillyTavern
    # only start listening after their modules/webpack are ready.  HTTP GETs
    # took 1-2 s each, which made the old launcher take over 30 seconds for a
    # simple "reuse everything" run.  Cache successful probes for 10 s.
    if ($script:ReadyCache.ContainsKey($Url)) {
        $cached = $script:ReadyCache[$Url]
        if (((Get-Date) - $cached.At).TotalSeconds -lt 10) { return $true }
    }
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    $port = $uri.Port
    if ($port -le 0) { $port = 80 }
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync($uri.Host, $port)
        if (-not $task.Wait(1500)) { return $false }
        $ok = ($task.IsFaulted -eq $false -and $client.Connected)
        if ($ok) {
            $script:ReadyCache[$Url] = [pscustomobject]@{ At = Get-Date }
        }
        return $ok
    } catch {
        return $false
    } finally {
        if ($client) { $client.Dispose() }
    }
}

function Show-TargetPorts {
    Say 'Target port status before starting:' 'Cyan'
    $rows = foreach ($s in $Services) {
        $o = Get-PortOwner $s.Port
        if ($o) {
            [pscustomobject]@{
                Service = $s.Name
                Port    = $s.Port
                State   = 'OCCUPIED'
                PID     = $o.Pid
                Process = $o.Name
                Path    = $o.Path
            }
        } else {
            [pscustomobject]@{
                Service = $s.Name
                Port    = $s.Port
                State   = 'free'
                PID     = ''
                Process = ''
                Path    = ''
            }
        }
    }
    ($rows | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host
}

function Save-PortReport([string]$Path) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('=== Qing launcher port report ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===')
    $lines.Add('')
    $lines.Add('--- Target ports ---')
    foreach ($s in $Services) {
        $o = Get-PortOwner $s.Port
        if ($o) {
            $http = 'no TCP'
            if (Test-Ready $s.Url) { $http = 'TCP OK' }
            $lines.Add(('{0} | port {1} | LISTEN | PID {2} | {3} | {4} | {5}' -f $s.Name, $s.Port, $o.Pid, $o.Name, $http, $o.Path))
        } else {
            $lines.Add(('{0} | port {1} | free' -f $s.Name, $s.Port))
        }
    }
    $lines.Add('')
    $lines.Add('--- All listening TCP ports ---')
    $procCache = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procCache[[int]$_.Id] = $_ }
    $netstatRows = New-Object System.Collections.Generic.List[object]
    try {
        $netstat = & netstat.exe -ano -p tcp 2>$null
        foreach ($line in $netstat) {
            if ($line -match '^\s*TCP(?:v6)?\s+(\S+)\s+\S+\s+LISTENING\s+(\d+)\s*$') {
                $local = [string]$matches[1]
                $ownerPid = [int]$matches[2]
                $idx = $local.LastIndexOf(':')
                if ($idx -lt 0) { continue }
                $portText = $local.Substring($idx + 1)
                if ($portText -notmatch '^\d+$') { continue }
                $netstatRows.Add([pscustomobject]@{
                    Port    = [int]$portText
                    Address = $local.Substring(0, $idx)
                    Pid     = $ownerPid
                })
            }
        }
    } catch { }
    foreach ($c in ($netstatRows | Sort-Object Port)) {
        $p = $procCache[[int]$c.Pid]
        $pname = '?'
        $ppath = ''
        if ($p) {
            $pname = $p.ProcessName
            $ppath = [string]$p.Path
        }
        $lines.Add(('{0,-6} {1,-16} PID {2,-6} {3,-28} {4}' -f $c.Port, $c.Address, $c.Pid, $pname, $ppath))
    }
    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Repair-ProxyEnvironment {
    # Some proxy tools / IDEs put [::1] or ::1 into NO_PROXY.
    # httpx 0.27 throws InvalidURL on such entries, so gradio cannot be
    # imported and ports 9872 / 9874 never start listening.
    foreach ($name in @('NO_PROXY', 'no_proxy')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not $value) { continue }
        $keep = @()
        foreach ($item in ($value -split ',')) {
            $t = $item.Trim()
            if (-not $t) { continue }
            if ($t -match '[\[\]]') { continue }
            if ($t -eq '::1') { continue }
            $keep += $t
        }
        foreach ($must in @('localhost', '127.0.0.1')) {
            if ($keep -notcontains $must) { $keep += $must }
        }
        $new = ($keep -join ',')
        [Environment]::SetEnvironmentVariable($name, $new, 'Process')
        if ($new -ne $value) {
            Say ('Sanitized {0} -> {1}' -f $name, $new) 'DarkYellow'
        }
    }
    # Disable gradio telemetry: offline / proxied networks make its startup
    # thread block on TLS handshakes.
    $env:GRADIO_ANALYTICS_ENABLED = 'False'
}

function Start-ServiceWindow($Service, [string]$LogPath) {
    $runner = Join-Path $PSScriptRoot $Service.Runner
    if (-not (Test-Path -LiteralPath $runner)) { throw "Missing runner script: $runner" }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -LogPath "{1}"' -f $runner, $LogPath
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments | Out-Null
    $script:PortMapAt = [datetime]::MinValue
}

function Test-OwnProcess($Owner, $Service) {
    if (-not $Owner) { return $false }
    $cmdLine = [string]$Owner.CommandLine
    if (-not $cmdLine) {
        $proc = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$Owner.Pid) -ErrorAction SilentlyContinue
        if ($proc) { $cmdLine = [string]$proc.CommandLine }
    }
    if (-not $cmdLine) { return $false }
    $leaf = Split-Path -Leaf $Service.Script
    if ($leaf -ieq 'server.js') {
        return ($cmdLine -match '(?i)server\.js')
    }
    # Match the exact script leaf.  A plain wildcard such as *webui.py* would
    # also match inference_webui.py, which belongs to a different service.
    $pattern = '(?i)(^|[\\/\s"])' + [regex]::Escape($leaf) + '($|[\s"])'
    return ($cmdLine -match $pattern)
}

function Wait-Ready([string]$Name, [string]$Url, [int]$Timeout, [string]$LogPath) {
    $start = Get-Date
    $until = $start.AddSeconds($Timeout)
    $last = $start
    while ((Get-Date) -lt $until) {
        if (Test-Ready $Url) {
            Say ('{0} is ready: {1} (after {2:N0}s)' -f $Name, $Url, ((Get-Date) - $start).TotalSeconds) 'Green'
            return $true
        }
        if (((Get-Date) - $last).TotalSeconds -ge 15) {
            Say ('Waiting for {0}... {1:N0}s elapsed' -f $Name, ((Get-Date) - $start).TotalSeconds) 'Yellow'
            $last = Get-Date
        }
        Start-Sleep -Seconds 2
    }
    Say ('{0} did not respond within {1} seconds: {2}' -f $Name, $Timeout, $Url) 'Red'
    foreach ($candidate in @($LogPath, ($LogPath + '.err.log'))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            Say ('Last lines of ' + $candidate + ':') 'Red'
            Get-Content -LiteralPath $candidate -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Host ('    ' + $_) -ForegroundColor DarkGray
            }
        }
    }
    return $false
}


function Ensure-Service($Service) {
    $owner = Get-PortOwner $Service.Port

    if ($owner) {
        Say ('{0} port {1} is already used by PID {2} ({3}).' -f $Service.Name, $Service.Port, $owner.Pid, $owner.Name) 'Yellow'
        if (Test-Ready $Service.Url) {
            Say ('Reusing the running {0}.' -f $Service.Name) 'Green'
            return $true
        }
        if (Test-OwnProcess $owner $Service) {
            if ($ForceRestart) {
                Say ('-ForceRestart: stopping our own PID {0} and starting a fresh copy.' -f $owner.Pid) 'Yellow'
                try {
                    Stop-Process -Id $owner.Pid -Force -ErrorAction Stop
                } catch {
                    Say ('Failed to stop PID {0}: {1}' -f $owner.Pid, $_.Exception.Message) 'Red'
                    return $false
                }
                for ($i = 0; $i -lt 30; $i++) {
                    Start-Sleep -Milliseconds 500
                    if (-not (Get-PortOwner $Service.Port)) { break }
                }
                if (Get-PortOwner $Service.Port) {
                    Say ('Port {0} is still occupied after stopping PID {1}.' -f $Service.Port, $owner.Pid) 'Red'
                    return $false
                }
            } else {
                # The process belongs to us but HTTP is not ready yet.  It is
                # most likely still loading a model, so killing it here was the
                # cause of the duplicate-process/port-conflict bug.
                Say ('The port is held by our own {0} process, but HTTP is not ready yet.' -f $Service.Name) 'Yellow'
                Say 'It may still be loading (inference can take 10+ minutes). Waiting instead of killing it.' 'Yellow'
                $existingLog = Get-LatestServiceLog $Service
                return (Wait-Ready $Service.Name $Service.Url $Service.Timeout $existingLog)
            }
        } else {
            Say ('Port {0} is occupied by another program that does not answer HTTP.' -f $Service.Port) 'Red'
            Say ('  PID         : {0}' -f $owner.Pid) 'Red'
            Say ('  Process     : {0}' -f $owner.Name) 'Red'
            Say ('  Path        : {0}' -f $owner.Path) 'Red'
            Say ('  CommandLine : {0}' -f $owner.CommandLine) 'Red'
            Say 'Close that program (or use StopQingAll) and run the launcher again.' 'Red'
            return $false
        }
    }

    $log = Join-Path $LogDir ('{0}_{1}.log' -f $Service.LogName, $Stamp)
    Say ('Starting {0} ... log: {1}' -f $Service.Name, $log) 'Cyan'
    Start-ServiceWindow $Service $log
    $script:PortMapAt = [datetime]::MinValue
    if ($script:ReadyCache.ContainsKey($Service.Url)) { $script:ReadyCache.Remove($Service.Url) }
    return (Wait-Ready $Service.Name $Service.Url $Service.Timeout $log)
}

# ---------------------------------------------------------------------------

Clear-Host
Say 'Qing one-click launcher' 'Cyan'
Say ('Root        : ' + $Root)
Say ('SillyTavern : ' + $ST)
Say ('Node        : ' + $Node)
Say ('Log folder  : ' + $LogDir)
Write-Host ''

# Single-instance lock.  The watchdog used to start a second launcher while
# the first one was still loading models; the second launcher then treated the
# loading processes as "stale" and killed them.  The mutex prevents that race.
$hasLauncherLock = $true
try {
    $launcherMutex = New-Object System.Threading.Mutex($false, $LauncherMutexName)
    try {
        $hasLauncherLock = $launcherMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # A previous launcher died without releasing the mutex; we own it now.
        $hasLauncherLock = $true
    }
} catch {
    Say ('Could not create launcher mutex (continuing without it): ' + $_.Exception.Message) 'Yellow'
    $hasLauncherLock = $true
}
if (-not $hasLauncherLock) {
    Say 'Another Qing launcher is already running or starting.' 'Yellow'
    Say 'This window will close in 3 seconds; the other launcher will finish the job.' 'Yellow'
    Start-Sleep -Seconds 3
    return
}

Repair-ProxyEnvironment
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$required = @(
    [pscustomobject]@{ Path = $Python;    Desc = 'GPT-SoVITS runtime python' }
    [pscustomobject]@{ Path = $MainWebUI; Desc = 'GPT-SoVITS webui.py' }
    [pscustomobject]@{ Path = $Inference; Desc = 'GPT-SoVITS inference_webui.py' }
    [pscustomobject]@{ Path = $Adapter;   Desc = 'Qing TTS adapter script' }
    [pscustomobject]@{ Path = $RefAudio;  Desc = 'Reference audio for TTS' }
    [pscustomobject]@{ Path = $Node;      Desc = 'node.exe' }
    [pscustomobject]@{ Path = (Join-Path $ST 'server.js'); Desc = 'SillyTavern server.js' }
)
$missing = $false
foreach ($item in $required) {
    if (-not (Test-Path -LiteralPath $item.Path)) {
        Say ('Required file missing ({0}): {1}' -f $item.Desc, $item.Path) 'Red'
        $missing = $true
    }
}
if ($missing) {
    Say 'Fix the missing files above, then run the launcher again.' 'Red'
    if ($hasLauncherLock -and $launcherMutex) {
        try { $launcherMutex.ReleaseMutex() } catch { }
        $launcherMutex.Dispose()
        $hasLauncherLock = $false
    }
    if (-not $NoPause) { Read-Host 'Press Enter to exit' }
    exit 1
}

Show-TargetPorts

# Startup order: main WebUI -> inference -> adapter (only after inference
# answers HTTP) -> SillyTavern.
$webuiOK   = Ensure-Service $Services[0]
$inferOK   = Ensure-Service $Services[1]
$adapterOK = $false
if ($inferOK) {
    $adapterOK = Ensure-Service $Services[2]
} else {
    Say 'Inference is not ready; adapter will not start (prevents ECONNREFUSED on port 9880).' 'Red'
}
$stOK = Ensure-Service $Services[3]

Write-Host ''
Say 'Final status:' 'Cyan'
$finalRows = foreach ($s in $Services) {
    $o = Get-PortOwner $s.Port
    $state = 'not listening'
    $procId = ''
    if ($o) {
        $procId = $o.Pid
        if (Test-Ready $s.Url) { $state = 'ready (TCP OK)' } else { $state = 'listening, no TCP' }
    }
    [pscustomobject]@{ Service = $s.Name; Port = $s.Port; State = $state; PID = $procId; Url = $s.Url }
}
($finalRows | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host

$report = Join-Path $LogDir ('port_report_' + $Stamp + '.txt')
try {
    Save-PortReport $report
    Say ('Port report written to ' + $report) 'Gray'
} catch {
    Say ('Could not write port report: ' + $_.Exception.Message) 'Yellow'
}

if (-not $NoBrowser) {
    Say 'Opening ready webpages...' 'Cyan'
    foreach ($s in $Services) {
        if (Test-Ready $s.Url) { Start-Process $s.Url | Out-Null }
    }
}

Write-Host ''
if ($inferOK -and $adapterOK -and $stOK) {
    Say 'Startup complete: inference, adapter and SillyTavern are listening.' 'Green'
} else {
    Say 'Startup finished, but at least one service failed. Check the messages and log files above.' 'Yellow'
    if (-not $inferOK)   { Say '  - GPT-SoVITS inference failed (port 9872).' 'Yellow' }
    if (-not $adapterOK) { Say '  - Qing TTS adapter failed (port 9880). SillyTavern TTS will get ECONNREFUSED 9880.' 'Yellow' }
    if (-not $stOK)      { Say '  - SillyTavern failed (port 8000).' 'Yellow' }
}
if ($hasLauncherLock -and $launcherMutex) {
    try { $launcherMutex.ReleaseMutex() } catch { }
    $launcherMutex.Dispose()
    $hasLauncherLock = $false
}
Say 'Launcher lock released; services keep running.' 'DarkGray'
if (-not $NoPause) {
    Read-Host 'Press Enter to close this launcher (services keep running)'
}

