param([string]$LogPath)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_config.ps1')

$root = $QingConfig.GptSoVITS

if (-not $LogPath) {
    $LogPath = Join-Path $QingConfig.LogDir ('gpt_sovits_inference_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

# 必须显式指定 v3 + 晴小姐自己的权重：
# 不指定时 inference_webui 会退到官方 v2 底模（s2G2333k.pth），
# 听起来就是"音色像但很怪"的零样本克隆效果。
$ModelVersion = 'v3'
$GptPath = $QingConfig.GptWeights
$SovitsPath = $QingConfig.SovitsWeights

if (-not (Test-Path $GptPath)) {
    Write-Host "找不到 GPT 权重：$GptPath，回退到默认"
    $ModelVersion = 'v2'
    $GptPath = ''
    $SovitsPath = ''
}

$envs = @{ PYTHONIOENCODING = 'utf-8' }
if ($ModelVersion -eq 'v3') {
    $envs['version'] = 'v3'
    $envs['gpt_path'] = $GptPath
    $envs['sovits_path'] = $SovitsPath
}

& (Join-Path $PSScriptRoot 'Run-Service.ps1') `
    -Title 'GPT-SoVITS Inference' `
    -Exe (Join-Path $root 'runtime\python.exe') `
    -Arguments @('-u', (Join-Path $root 'GPT_SoVITS\inference_webui.py'), 'zh_CN') `
    -WorkDir $root `
    -LogPath $LogPath `
    -Environment $envs


