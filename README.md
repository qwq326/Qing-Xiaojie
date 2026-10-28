# 晴小姐 · Qing Xiaojie

> 一个用 **GPT-SoVITS v3（LoRA）** 训练出来的中文语音模型，附带一键启动器与 OpenAI 兼容的 TTS 适配器。

- 🎙️ **模型本体**：`晴2.0-e25.ckpt`（GPT，155 MB）+ `晴2.0_e3_s876_l64.pth`（SoVITS，87 MB）
- 🧠 **训练数据**：300 条中文语音（约 36.8 MB OGG）+ 逐条对齐文本
- ⚡ **一键启动**：按依赖顺序拉起 WebUI → 推理服务 → TTS 适配器 → SillyTavern，带端口检查、日志、单实例锁
- 🔌 **OpenAI 兼容**：`POST /v1/audio/speech`，SillyTavern / 任何 OpenAI TTS 客户端直接可用
- 🎭 **情绪参考**：按情绪（日常/开心/害羞/生气/惊讶/伤心/吃醋/无语）自动切换参考音频

> ⚠️ 这是**声音克隆**模型，请仅用于合法、经授权的场景；禁止用于冒充他人、诈骗或任何违法用途。详见 [LICENSE-MODELS.md](LICENSE-MODELS.md)。

---

## 目录结构

```
.
├─ adapter/
│  └─ qing_tts_adapter.py      OpenAI 兼容 TTS 适配器（9880）
├─ launcher/                   一键启动/停止/端口检查（PowerShell）
│  ├─ 启动晴小姐.bat           ← 日常双击这个
│  ├─ 停止晴小姐.bat
│  ├─ 检查端口占用.bat
│  ├─ StartQingAll.ps1         启动编排（单实例锁 + 端口诊断 + 看门狗兼容）
│  ├─ StopQingAll.ps1          停止全部服务（含重复进程清理）
│  ├─ Run-GPTWebUI.ps1         GPT-SoVITS WebUI      :9874
│  ├─ Run-Inference.ps1        GPT-SoVITS 推理服务    :9872
│  ├─ Run-Adapter.ps1          晴小姐 TTS 适配器      :9880
│  ├─ Run-SillyTavern.ps1      SillyTavern            :8000
│  ├─ Show-Ports.ps1           端口占用报告
│  ├─ InstallDesktopShortcut.ps1  创建桌面快捷方式
│  └─ _config.ps1              配置加载器
├─ config/tts_params.json      采样参数（top_k / top_p / temperature / speed …）
├─ voice_refs/
│  ├─ 000001.ogg               默认参考音频（5 秒）
│  └─ refs.json                情绪 → 参考音频映射（可选）
├─ models/                     模型权重下载脚本与说明（权重本身不入库）
├─ docs/使用说明.md            详细使用说明
├─ config.example.ps1          配置模板 → 复制成 config.ps1
└─ README.md
```

## 四个服务与端口

| 服务 | 端口 | 作用 |
| --- | --- | --- |
| GPT-SoVITS WebUI | 9874 | 浏览器里手动试听/训练界面（可选） |
| GPT-SoVITS inference | 9872 | Gradio 推理 API，真正跑模型的地方 |
| 晴小姐 TTS 适配器 | 9880 | OpenAI 兼容层，SillyTavern 调这个 |
| SillyTavern | 8000 | 聊天前端（可选） |

启动顺序固定为 **9874 → 9872 → 9880 → 8000**：适配器必须等推理服务 HTTP 就绪后才启动，否则 SillyTavern 会收到 `ECONNREFUSED 127.0.0.1:9880`。

## 快速开始

### 1. 准备 GPT-SoVITS 整合包

下载并解压 [GPT-SoVITS](https://github.com/RVC-Boss/GPT-SoVITS)（Windows 整合包，**必须带 `runtime\python.exe`**），例如解压到 `D:\GPT-SoVITS`。

### 2. 下载模型权重

```powershell
# 在本仓库根目录执行；默认下载到 models\
powershell -ExecutionPolicy Bypass -File models\download-models.ps1
```

然后把它们放到 GPT-SoVITS 的权重目录（文件名里的 `e25` / `e3_s876_l64` 会被 GPT-SoVITS 解析成 epoch/step，别改）：

```
<GPT-SoVITS>\GPT_weights_v3\Qing2.0-e25.ckpt
<GPT-SoVITS>\SoVITS_weights_v3\Qing2.0_e3_s876_l64.pth
```

> 也可以直接从 [Releases](../../releases) 页面手动下载。

### 3. 配置路径

```powershell
copy config.example.ps1 config.ps1
notepad config.ps1
```

最少要改 `GptSoVITS`、`GptWeights`、`SovitsWeights` 三项；`SillyTavern` 不需要可留空（新手建议先填上，启动器会一起拉起来）。

`config.ps1` 已在 `.gitignore` 中，不会被提交。

### 4. 启动

双击 `launcher\启动晴小姐.bat`（或桌面快捷方式，先运行一次 `安装桌面快捷方式.bat`）。

首次加载模型可能较慢（历史上出现过约 10 分钟），启动器对推理服务的超时放宽到 30 分钟，并会实时写入日志：

```
<LogDir>\gpt_sovits_main_<时间>.log
<LogDir>\gpt_sovits_inference_<时间>.log
<LogDir>\qing_tts_adapter_<时间>.log
<LogDir>\sillytavern_<时间>.log
```

## 模型文件

| 文件 | 类型 | 大小 | SHA256 |
| --- | --- | --- | --- |
| `Qing2.0-e25.ckpt` | GPT（音色/韵律） | 155,312,438 B | `71860F8B821C1E66419F98CCBCBA99D9D34CF2300E41ADABF7CE35F9DAE51825` |
| `Qing2.0_e3_s876_l64.pth` | SoVITS（声码/音质） | 87,084,285 B | `0A99E2534B4C4B93E23F06603920A72B3C095C081CC87184A252A1CD4335ABD3` |

- 训练配置：**GPT-SoVITS v3 + LoRA**，中文，300 条语料
- 单文件超过 GitHub 100 MB 限制，所以放在 **Release** 里，不直接进仓库（`models/*.ckpt`、`models/*.pth` 已 gitignore）

## 调用 TTS 接口

适配器实现了 OpenAI TTS 的常用字段：

```bash
curl -X POST http://127.0.0.1:9880/v1/audio/speech ^
  -H "Content-Type: application/json" ^
  -d "{\"input\":\"今天也要好好休息哦。\",\"voice\":\"晴小姐\"}" --output out.wav
```

```python
import requests

r = requests.post(
    "http://127.0.0.1:9880/v1/audio/speech",
    json={"input": "今天也要好好休息哦。", "voice": "晴小姐", "emotion": "开心"},
    timeout=120,
)
open("out.wav", "wb").write(r.content)
```

| 字段 | 说明 |
| --- | --- |
| `input` / `text` | 要合成的文本（必填） |
| `voice` | 说话人，默认 `晴小姐`；填情绪词（如 `害羞`）等价于传 `emotion` |
| `emotion` / `referenceId` | 情绪桶名，见下 |

其它接口：`GET /`（健康检查）、`GET /speakers`（说话人列表）。

### SillyTavern 设置

`扩展 → TTS → 提供商选 "OpenAI"`：

| 项 | 值 |
| --- | --- |
| 基础 URL | `http://127.0.0.1:9880/v1` |
| API Key | 随便填（本地不校验） |
| 模型/语音 | `晴小姐`（或 `tts-1`） |
| 格式 | wav |

## 情绪参考音频（可选）

`voice_refs/refs.json` 把情绪映射到参考音频，适配器按 `emotion → 别名 → 日常 → 默认` 的顺序挑选：

```json
{
  "default": [
    { "ref": "voice_refs/000001.ogg", "prompt": "早上好看你没什么反应的样子，是已经习惯了自己的新身体吗？" }
  ],
  "开心": [
    { "ref": "voice_refs/开心_000387.ogg", "prompt": "话说回来！您还记得，我是谁吗？" }
  ],
  "害羞": [
    { "ref": "voice_refs/害羞_000552.ogg", "prompt": "在未来的无数个时间点，你都会无数次地遇见我。" }
  ]
}
```

- `ref` 可以是相对仓库根目录的路径，也可以是绝对路径
- `prompt` 必须与参考音频**逐字对应**，否则音质会明显变差
- 没有该文件也能正常运行（只用默认参考音频）

## 采样参数

`config/tts_params.json`：

```json
{ "top_k": 20, "top_p": 0.6, "temperature": 0.6, "speed": 1.0, "sample_steps": 32, "pause_second": 0.3 }
```

`top_p` / `temperature` 调到 1.0（最大随机）时声音会“飘、含糊”；`speed` 影响语速，`sample_steps` 越大越清晰也越慢。

## 常见问题

**Q：SillyTavern 报 `ECONNREFUSED 127.0.0.1:9880`**
A：适配器没起来。先看 `<LogDir>\qing_tts_adapter_*.log`；最常见原因是推理服务（9872）还没就绪，或 `config.ps1` 里的参考音频/权重路径不对。

**Q：GPT-SoVITS 启动即退出，日志里有 `Invalid port ':1]'` / `InvalidURL`**
A：`NO_PROXY` 里带了 `[::1]` 或 `::1`，httpx 0.27 会直接报错。启动器（`Run-Service.ps1`）已自动清理该环境变量并设置 `GRADIO_ANALYTICS_ENABLED=False`；如果你是手动跑 python，请自己清一下。

**Q：音色“像但很怪”**
A：多半是没加载 v3 权重、退回了官方 v2 底模。检查 `config.ps1` 的 `GptWeights` / `SovitsWeights` 是否指向本仓库的两个模型，并看推理日志里的 `version=v3`。

**Q：提示无法运行脚本 / 执行策略**
A：`.bat` 已带 `-ExecutionPolicy Bypass`；如果手动跑 `.ps1`，用 `powershell -ExecutionPolicy Bypass -File xxx.ps1`。

**Q：端口被别的软件占用**
A：双击 `检查端口占用.bat` 看占用进程；确认不是本项目的残留进程后再启动。启动器会对“端口在监听但 HTTP 无响应”的自有进程做处理，但不会杀别人的程序。

**Q：想改端口**
A：改 `config.ps1` 里的 `WebUIPort` / `InferencePort` / `AdapterPort` / `STPort` —— 启动器、适配器、端口检查都会跟着变（SillyTavern 自己的 `config.yaml` 也要同步改）。

## 训练与调参记录

- 语料：300 条中文语音（OGG，约 36.8 MB），逐条人工校对文本
- 版本：GPT-SoVITS v3，LoRA 微调；GPT 训练到 epoch 25，SoVITS 取 `e3_s876_l64`
- 默认参考音频：`voice_refs/000001.ogg`（5 秒左右，情绪中性、无背景音）
- 经验：参考音频响度会直接影响输出音量，适配器因此做了峰值 0.94 / RMS 0.06 的归一化

## 许可

| 部分 | 许可 |
| --- | --- |
| 代码（`launcher/`、`adapter/`、脚本） | [MIT](LICENSE) |
| 模型权重与参考音频（Release 资产、`voice_refs/`） | [CC BY-NC-SA 4.0](LICENSE-MODELS.md) |

**禁止**：冒充真实人物、伪造他人语音、诈骗、制作违法内容、未授权的商业用途。

## 致谢

- [GPT-SoVITS](https://github.com/RVC-Boss/GPT-SoVITS) —— 语音克隆框架
- [SillyTavern](https://github.com/SillyTavern/SillyTavern) —— 聊天前端
- 训练语料与配音：本项目作者
