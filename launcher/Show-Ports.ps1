$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'Qing port checker'

. (Join-Path $PSScriptRoot '_config.ps1')

$LogDir = $QingConfig.LogDir
$Targets = @(
    [pscustomobject]@{ Name = 'GPT-SoVITS WebUI';     Port = $QingConfig.WebUIPort;     Url = ('http://127.0.0.1:{0}/' -f $QingConfig.WebUIPort) }
    [pscustomobject]@{ Name = 'GPT-SoVITS inference'; Port = $QingConfig.InferencePort; Url = ('http://127.0.0.1:{0}/' -f $QingConfig.InferencePort) }
    [pscustomobject]@{ Name = 'Qing TTS adapter';     Port = $QingConfig.AdapterPort;   Url = ('http://127.0.0.1:{0}/' -f $QingConfig.AdapterPort) }
    [pscustomobject]@{ Name = 'SillyTavern';          Port = $QingConfig.STPort;        Url = ('http://127.0.0.1:{0}/' -f $QingConfig.STPort) }
)

function Get-Owner([int]$Port) {
    $conn = $null
    try {
        $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Select-Object -First 1
    } catch {
        return $null
    }
    if (-not $conn) { return $null }
    $proc = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$conn.OwningProcess) -ErrorAction SilentlyContinue
    $name = '?'
    $path = ''
    $cmdLine = ''
    if ($proc) {
        $name = [string]$proc.Name
        $path = [string]$proc.ExecutablePath
        $cmdLine = [string]$proc.CommandLine
    }
    return [pscustomobject]@{
        Port = [int]$conn.LocalPort; Address = [string]$conn.LocalAddress
        Pid = [int]$conn.OwningProcess; Name = $name; Path = $path; CommandLine = $cmdLine
    }
}

function Test-Http([string]$Url) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Proxy = $null
        $req.Method = 'GET'
        $req.Timeout = 3000
        $req.ReadWriteTimeout = 3000
        $req.UserAgent = 'QingPortCheck'
        $resp = $req.GetResponse()
        try {
            $code = [int]$resp.StatusCode
        } finally {
            $resp.Close()
        }
        return ($code -ge 200 -and $code -lt 400)
    } catch {
        return $false
    }
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('=== Qing port report ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===')

Clear-Host
Write-Host '=== Target ports ===' -ForegroundColor Cyan
$rows = foreach ($t in $Targets) {
    $o = Get-Owner $t.Port
    if ($o) {
        $http = 'no'
        if (Test-Http $t.Url) { $http = 'yes' }
        $lines.Add(('{0} | port {1} | LISTEN | HTTP {2} | PID {3} | {4} | {5}' -f $t.Name, $t.Port, $http, $o.Pid, $o.Name, $o.Path))
        [pscustomobject]@{
            Service = $t.Name; Port = $t.Port; State = 'LISTEN'; HTTP = $http
            PID = $o.Pid; Process = $o.Name; Path = $o.Path
        }
    } else {
        $lines.Add(('{0} | port {1} | free' -f $t.Name, $t.Port))
        [pscustomobject]@{
            Service = $t.Name; Port = $t.Port; State = 'free'; HTTP = '-'
            PID = ''; Process = ''; Path = ''
        }
    }
}
($rows | Format-Table -AutoSize | Out-String -Width 250).TrimEnd() | Write-Host

Write-Host ''
Write-Host '=== All listening TCP ports ===' -ForegroundColor Cyan
$all = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Sort-Object LocalPort
$lines.Add('')
$lines.Add('--- All listening TCP ports ---')
$procCache = @{}
Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procCache[[int]$_.Id] = $_ }
$allRows = foreach ($c in $all) {
    $p = $procCache[[int]$c.OwningProcess]
    $pname = '?'
    $ppath = ''
    if ($p) {
        $pname = $p.ProcessName
        $ppath = [string]$p.Path
    }
    $lines.Add(('{0,-6} {1,-16} PID {2,-6} {3,-28} {4}' -f $c.LocalPort, $c.LocalAddress, $c.OwningProcess, $pname, $ppath))
    [pscustomobject]@{
        Port = $c.LocalPort; Address = $c.LocalAddress; PID = $c.OwningProcess
        Process = $pname; Path = $ppath
    }
}
($allRows | Format-Table -AutoSize | Out-String -Width 250).TrimEnd() | Write-Host

if (Test-Path -LiteralPath $LogDir) {
    $report = Join-Path $LogDir ('ports_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
    try {
        $lines | Set-Content -LiteralPath $report -Encoding UTF8
        Write-Host ''
        Write-Host ('Report saved to ' + $report) -ForegroundColor DarkGray
    } catch { }
}
