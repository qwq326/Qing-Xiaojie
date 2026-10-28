# ============================================================================
#  晴小姐 - 本机配置模板
#  用法：复制本文件为 config.ps1，按自己的实际路径修改（config.ps1 不会提交到 Git）
# ============================================================================

$QingConfig = @{
    # ---------- 必填 ----------
    # GPT-SoVITS 整合包根目录（里面应有 runtime\python.exe、webui.py、GPT_SoVITS\）
    GptSoVITS     = 'D:\GPT-SoVITS'

    # ---------- 模型权重 ----------
    GptWeights    = 'D:\GPT-SoVITS\GPT_weights_v3\Qing2.0-e25.ckpt'
    SovitsWeights = 'D:\GPT-SoVITS\SoVITS_weights_v3\Qing2.0_e3_s876_l64.pth'

    # ---------- 可选 ----------
    # SillyTavern 目录；留空则启动器跳过该服务
    SillyTavern   = 'D:\SillyTavern'
    Node          = 'D:\node.exe'

    LogDir        = 'logs'            # 相对路径 = 相对仓库根目录

    # 参考音频与适配器
    RefAudio      = 'voice_refs\000001.ogg'
    RefsJson      = 'voice_refs\refs.json'      # 情绪参考音频表，没有该文件也能跑（用默认参考）
    ParamsJson    = 'config\tts_params.json'
    OutputDir     = 'output'
    Adapter       = 'adapter\qing_tts_adapter.py'

    # ---------- 端口（如无冲突不建议改） ----------
    WebUIPort     = 9874
    InferencePort = 9872
    AdapterPort   = 9880
    STPort        = 8000
}
