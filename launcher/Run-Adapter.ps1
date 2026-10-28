param([string]$LogPath)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_config.ps1')

$root = $QingConfig.GptSoVITS

if (-not $LogPath) {
    $LogPath = Join-Path $QingConfig.LogDir ('qing_tts_adapter_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

& (Join-Path $PSScriptRoot 'Run-Service.ps1') `
    -Title 'Qing TTS Adapter' `
    -Exe (Join-Path $root 'runtime\python.exe') `
    -Arguments @('-u', $QingConfig.Adapter) `
    -WorkDir $root `
    -LogPath $LogPath `
    -Environment @{
        PYTHONIOENCODING = 'utf-8'
        QING_BACKEND     = ('http://127.0.0.1:' + $QingConfig.InferencePort)
        QING_PORT        = [string]$QingConfig.AdapterPort
        QING_REF_AUDIO   = $QingConfig.RefAudio
        QING_REFS_JSON   = $QingConfig.RefsJson
        QING_PARAMS_JSON = $QingConfig.ParamsJson
        QING_OUTPUT_DIR  = $QingConfig.OutputDir
    }


