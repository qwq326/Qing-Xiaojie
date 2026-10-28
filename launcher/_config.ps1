# ============================================================================
#  晴小姐启动器 - 配置加载器
#  被 StartQingAll.ps1 / Run-*.ps1 / StopQingAll.ps1 / Show-Ports.ps1 点源引用。
#
#  查找顺序：
#    1. 仓库根目录的 config.ps1（本机私有，已在 .gitignore 中）
#    2. 下面的默认值（相对路径全部以仓库根目录为基准）
# ============================================================================

$RepoRoot = Split-Path -Parent $PSScriptRoot

$QingDefaults = @{
    GptSoVITS     = ''                                             # GPT-SoVITS 整合包根目录（必填）
    SillyTavern   = ''                                             # SillyTavern 目录（可选，留空则跳过）
    Node          = 'node.exe'                                     # node.exe 路径（可用 PATH 中的 node）
    LogDir        = (Join-Path $RepoRoot 'logs')                   # 日志目录
    GptWeights    = ''                                             # GPT_weights_v3\xxx.ckpt
    SovitsWeights = ''                                             # SoVITS_weights_v3\xxx.pth
    RefAudio      = (Join-Path $RepoRoot 'voice_refs\000001.ogg')  # 默认参考音频
    RefsJson      = (Join-Path $RepoRoot 'voice_refs\refs.json')   # 情绪参考音频表（可选）
    ParamsJson    = (Join-Path $RepoRoot 'config\tts_params.json') # 采样参数（可选）
    OutputDir     = (Join-Path $RepoRoot 'output')                 # 合成音频保存目录
    Adapter       = (Join-Path $RepoRoot 'adapter\qing_tts_adapter.py')

    # 端口
    WebUIPort     = 9874
    InferencePort = 9872
    AdapterPort   = 9880
    STPort        = 8000
}

$QingConfig = @{}
$QingConfigFile = Join-Path $RepoRoot 'config.ps1'
if (Test-Path -LiteralPath $QingConfigFile) {
    . $QingConfigFile      # config.ps1 里定义 $QingConfig 哈希表，覆盖上面的默认值
}

foreach ($key in @($QingDefaults.Keys)) {
    if (-not $QingConfig.ContainsKey($key) -or -not $QingConfig[$key]) {
        $QingConfig[$key] = $QingDefaults[$key]
    }
}

# 相对路径统一按仓库根目录解析（Node 除外，它可能是 PATH 里的 node.exe）
foreach ($key in @('GptSoVITS', 'SillyTavern', 'LogDir', 'GptWeights', 'SovitsWeights',
                   'RefAudio', 'RefsJson', 'ParamsJson', 'OutputDir', 'Adapter')) {
    $value = $QingConfig[$key]
    if ($value -and -not [System.IO.Path]::IsPathRooted([string]$value)) {
        $QingConfig[$key] = Join-Path $RepoRoot ([string]$value)
    }
}

function Assert-QingConfig {
    if (-not $QingConfig.GptSoVITS) {
        Write-Host '未配置 GPT-SoVITS 路径。' -ForegroundColor Red
        Write-Host '请把 config.example.ps1 复制为 config.ps1，并填写 GptSoVITS 等路径。' -ForegroundColor Yellow
        return $false
    }
    if (-not (Test-Path -LiteralPath $QingConfig.GptSoVITS)) {
        Write-Host ('GPT-SoVITS 目录不存在：' + $QingConfig.GptSoVITS) -ForegroundColor Red
        return $false
    }
    return $true
}
