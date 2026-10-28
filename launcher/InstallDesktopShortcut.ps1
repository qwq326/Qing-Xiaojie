$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot '启动晴小姐.bat'
$stopper  = Join-Path $PSScriptRoot '停止晴小姐.bat'
foreach ($f in @($launcher, $stopper)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing launcher: $f" }
}

$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell

function New-QingShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Icon,
        [int]$WindowStyle = 1
    )
    $path = Join-Path $desktop $Name
    $link = $shell.CreateShortcut($path)
    $link.TargetPath = $Target
    $link.WorkingDirectory = $PSScriptRoot
    $link.Description = $Description
    $link.IconLocation = $Icon
    $link.WindowStyle = $WindowStyle
    $link.Save()
    Write-Host ('Created: ' + $path) -ForegroundColor Green
}

New-QingShortcut -Name '晴小姐AI - 启动.lnk' -Target $launcher `
    -Description '按依赖顺序启动 GPT-SoVITS / 晴小姐 TTS 适配器 / SillyTavern' `
    -Icon "$env:SystemRoot\System32\shell32.dll,137" -WindowStyle 7

New-QingShortcut -Name '晴小姐AI - 停止.lnk' -Target $stopper `
    -Description '停止晴小姐的全部服务' `
    -Icon "$env:SystemRoot\System32\shell32.dll,27"

Write-Host ''
Write-Host 'Desktop shortcuts are ready.' -ForegroundColor Cyan
Write-Host '- 晴小姐AI - 启动 (minimized, starts everything)' -ForegroundColor Gray
Write-Host '- 晴小姐AI - 停止 (stops everything)' -ForegroundColor Gray
