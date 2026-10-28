param([string]$LogPath)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_config.ps1')

$root = $QingConfig.SillyTavern
$Node = $QingConfig.Node

if (-not $LogPath) {
    $LogPath = Join-Path $QingConfig.LogDir ('sillytavern_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

& (Join-Path $PSScriptRoot 'Run-Service.ps1') `
    -Title 'SillyTavern' `
    -Exe $Node `
    -Arguments @('server.js') `
    -WorkDir $root `
    -LogPath $LogPath `
    -Environment @{ NODE_ENV = 'production' }


