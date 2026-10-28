# 模型权重下载

权重体积超过 GitHub 单文件 100 MB 限制，因此放在 **Release** 里，仓库只保留下载脚本。

| 文件 | 类型 | 大小 | SHA256 |
| --- | --- | --- | --- |
| `Qing2.0-e25.ckpt` | GPT（音色/韵律） | 155,312,438 B | `71860F8B821C1E66419F98CCBCBA99D9D34CF2300E41ADABF7CE35F9DAE51825` |
| `Qing2.0_e3_s876_l64.pth` | SoVITS（声码/音质） | 87,084,285 B | `0A99E2534B4C4B93E23F06603920A72B3C095C081CC87184A252A1CD4335ABD3` |

## 一键下载

```powershell
powershell -ExecutionPolicy Bypass -File models\download-models.ps1
```

脚本会下载到 `models\` 并校验 SHA256。指定版本/目录：

```powershell
powershell -ExecutionPolicy Bypass -File models\download-models.ps1 -Tag v1.0.0 -Dest D:\models
```

## 手动下载 + 放置

1. 打开仓库的 **Releases** 页面，下载上面两个文件
2. 放进 GPT-SoVITS 整合包的权重目录：

```
<GPT-SoVITS>\GPT_weights_v3\Qing2.0-e25.ckpt
<GPT-SoVITS>\SoVITS_weights_v3\Qing2.0_e3_s876_l64.pth
```

3. 在 `config.ps1` 里把 `GptWeights` / `SovitsWeights` 指向这两个文件

> 文件名里的 `e25`、`e3_s876_l64` 会被 GPT-SoVITS 解析成 epoch / step / layer，
> **不要改这些数字**；前面的 `Qing2.0` 可以改，但建议保持一致。

## 许可

模型权重采用 **CC BY-NC-SA 4.0**：可自由使用、修改、分享，但**禁止商业用途**，且禁止用于冒充他人或任何违法场景。详见 [../LICENSE-MODELS.md](../LICENSE-MODELS.md)。
