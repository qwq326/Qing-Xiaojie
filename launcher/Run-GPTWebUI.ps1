param([string]$LogPath)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_config.ps1')

$root = $QingConfig.GptSoVITS

if (-not $LogPath) {
    $LogPath = Join-Path $QingConfig.LogDir ('gpt_sovits_main_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

& (Join-Path $PSScriptRoot 'Run-Service.ps1') `
    -Title 'GPT-SoVITS WebUI' `
    -Exe (Join-Path $root 'runtime\python.exe') `
    -Arguments @('-u', (Join-Path $root 'webui.py'), 'zh_CN') `
    -WorkDir $root `
    -LogPath $LogPath `
    -Environment @{ PYTHONIOENCODING = 'utf-8' }


