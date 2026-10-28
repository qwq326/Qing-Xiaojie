param(
    [string]$Title = 'Qing service',
    [Parameter(Mandatory = $true)][string]$Exe,
    [string[]]$Arguments = @(),
    [Parameter(Mandatory = $true)][string]$WorkDir,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [hashtable]$Environment = @{}
)

$ErrorActionPreference = 'Continue'
try { $Host.UI.RawUI.WindowTitle = $Title } catch { }

$logDir = Split-Path -Parent $LogPath
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$errPath = $LogPath + '.err.log'

# Start-Process writes the child's stdout/stderr directly to these files, so
# the launcher can read them while the model is still loading.  The old
# PowerShell pipeline kept the output buffered until the process exited, which
# is why some logs looked empty (0 bytes) during long startups.
[IO.File]::WriteAllText($LogPath, '', (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($errPath, '', (New-Object System.Text.UTF8Encoding($false)))

Set-Location -LiteralPath $WorkDir

# httpx 0.27 treats "[::1]" / "::1" in NO_PROXY as an invalid URL and raises
# Invalid port ':1]', which kills the adapter before it binds port 9880.
# StartQingAll.ps1 already sanitizes its own process, but a runner started
# directly (or by the watchdog) needs the same protection.
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
        Write-Host ('Sanitized {0} -> {1}' -f $name, $new) -ForegroundColor DarkYellow
    }
}
$env:GRADIO_ANALYTICS_ENABLED = 'False'

foreach ($key in $Environment.Keys) {
    Set-Item -Path ('Env:' + $key) -Value ([string]$Environment[$key])
}
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

Write-Host ('Service : ' + $Title) -ForegroundColor Cyan
Write-Host ('Log file: ' + $LogPath) -ForegroundColor DarkGray
Write-Host ('Stderr  : ' + $errPath) -ForegroundColor DarkGray
Write-Host 'Output is written to the log file in real time.' -ForegroundColor DarkGray
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray

$argLine = ($Arguments | ForEach-Object {
    if ([string]$_ -match '\s') { '"' + $_ + '"' } else { $_ }
}) -join ' '

try {
    $proc = Start-Process -FilePath $Exe -ArgumentList $argLine -WorkingDirectory $WorkDir `
        -NoNewWindow -PassThru -RedirectStandardOutput $LogPath -RedirectStandardError $errPath
} catch {
    Write-Host ('Failed to start service: ' + $_.Exception.Message) -ForegroundColor Red
    Add-Content -LiteralPath $LogPath -Value ('Failed to start: ' + $_.Exception.Message) -Encoding UTF8
    Start-Sleep -Seconds 5
    exit 1
}

Write-Host ('PID     : ' + $proc.Id) -ForegroundColor DarkGray
$proc.WaitForExit()
$code = $proc.ExitCode

try {
    $errText = [IO.File]::ReadAllText($errPath, [Text.Encoding]::UTF8)
    if ($errText.Trim().Length -gt 0) {
        Add-Content -LiteralPath $LogPath -Value ("`r`n--- stderr ---`r`n" + $errText) -Encoding UTF8
    }
} catch { }

if ($null -ne $code -and $code -ne 0) {
    Write-Host ('Service exited with code ' + $code) -ForegroundColor Red
} else {
    Write-Host 'Service exited.' -ForegroundColor Yellow
}
Start-Sleep -Seconds 3
