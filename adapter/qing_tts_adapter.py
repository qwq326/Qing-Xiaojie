"""晴小姐 TTS 适配器
================================================================================
把 GPT-SoVITS 的 Gradio 推理服务包装成 OpenAI 兼容的 TTS 接口，供 SillyTavern
（或任何支持 OpenAI TTS 的客户端）直接调用。

    POST /v1/audio/speech   {"input": "你好", "voice": "晴小姐"}  ->  audio/wav
    GET  /                  健康检查
    GET  /speakers          说话人列表（OpenAI TTS 客户端探测用）

路径全部可以用环境变量覆盖（启动器 launcher/Run-Adapter.ps1 会自动注入）：
    QING_HOST / QING_PORT     监听地址与端口          默认 127.0.0.1:9880
    QING_BACKEND              GPT-SoVITS 推理服务地址  默认 http://127.0.0.1:9872
    QING_REF_AUDIO            默认参考音频             默认 <repo>/voice_refs/000001.ogg
    QING_PROMPT_TEXT          默认参考音频对应的文本
    QING_REFS_JSON            情绪 -> 参考音频映射表   默认 <repo>/voice_refs/refs.json
    QING_PARAMS_JSON          采样参数                 默认 <repo>/config/tts_params.json
    QING_OUTPUT_DIR           合成结果保存目录         默认 <repo>/output
================================================================================
"""

import json
import os
import random
import re
import shutil
import uuid
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

try:
    from gradio_client import Client, file
except ImportError:  # 典型原因：没有用 GPT-SoVITS 整合包里的 runtime\python.exe
    raise SystemExit(
        "缺少 gradio_client。请使用 GPT-SoVITS 整合包自带的 Python 运行本脚本，"
        "例如 <GPT-SoVITS>\\runtime\\python.exe adapter\\qing_tts_adapter.py"
    )

REPO_ROOT = Path(__file__).resolve().parent.parent

HOST = os.environ.get("QING_HOST", "127.0.0.1")
PORT = int(os.environ.get("QING_PORT", "9880"))
BACKEND = os.environ.get("QING_BACKEND", "http://127.0.0.1:9872")

REF_AUDIO = os.environ.get("QING_REF_AUDIO", str(REPO_ROOT / "voice_refs" / "000001.ogg"))
REFS_JSON = os.environ.get("QING_REFS_JSON", str(REPO_ROOT / "voice_refs" / "refs.json"))
PARAMS_JSON = os.environ.get("QING_PARAMS_JSON", str(REPO_ROOT / "config" / "tts_params.json"))
OUTPUT_DIR = os.environ.get("QING_OUTPUT_DIR", str(REPO_ROOT / "output"))

PROMPT_TEXT = os.environ.get(
    "QING_PROMPT_TEXT",
    "早上好看你没什么反应的样子，是已经习惯了自己的新身体吗？",
)

# 情绪别名：上层传来的情绪没有对应参考音频时，退到相近的那一桶
EMO_ALIAS = {
    "吃醋": "害羞",
    "无语": "日常",
    "撒娇": "害羞",
    "害怕": "惊讶",
    "疑惑": "惊讶",
    "温柔": "日常",
    "疲惫": "日常",
}

REFS = {}


def _resolve(path):
    """相对路径按仓库根目录解析（方便 refs.json 里直接写 voice_refs/xxx.ogg）。"""
    if not path:
        return path
    return path if os.path.isabs(path) else str(REPO_ROOT / path)


def _load_refs():
    """读取 refs.json：{ "情绪": [{"ref": "音频路径", "prompt": "文本"}, ...] }"""
    try:
        with open(REFS_JSON, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        print("未找到情绪参考音频表（可选）：", REFS_JSON)
        return {}
    except Exception as exc:
        print("情绪参考音频加载失败：", repr(exc))
        return {}

    out = {}
    for key, val in data.items():
        if key == "default":
            continue
        items = val if isinstance(val, list) else [val]
        picked = [
            (_resolve(item["ref"]), item.get("prompt") or "")
            for item in items
            if isinstance(item, dict) and item.get("ref") and os.path.isfile(_resolve(item["ref"]))
        ]
        if picked:
            out[key] = picked
    return out


def load_default_ref():
    """refs.json 里的 default 优先，其次是 QING_REF_AUDIO。"""
    global REF_AUDIO, PROMPT_TEXT
    try:
        with open(REFS_JSON, encoding="utf-8") as fh:
            data = json.load(fh)
        items = data.get("default")
        items = items if isinstance(items, list) else [items]
        for item in items:
            if isinstance(item, dict) and item.get("ref") and os.path.isfile(_resolve(item["ref"])):
                REF_AUDIO = _resolve(item["ref"])
                PROMPT_TEXT = item.get("prompt") or PROMPT_TEXT
                return
    except Exception:
        pass


def pick_ref(emotion):
    """按情绪挑一条参考音频，返回 (路径, 参考文本, 桶名)。"""
    key = (emotion or "").strip()
    for candidate in (key, EMO_ALIAS.get(key), "日常", "default"):
        if candidate and candidate in REFS:
            ref, prompt = random.choice(REFS[candidate])
            return ref, prompt, candidate
    return REF_AUDIO, PROMPT_TEXT, "默认"


def normalize_wav(path, target_peak=0.94, target_rms=0.06):
    """峰值/RMS 归一 + 头尾静音裁剪。

    模型会跟着参考音频的音量走，参考偏轻时输出几乎听不见，所以这里做一次归一。
    """
    try:
        import numpy as np
        import soundfile as sf

        data, sr = sf.read(path, dtype="float32", always_2d=True)
        if data.size == 0:
            return path
        peak = float(np.max(np.abs(data)))
        rms = float(np.sqrt(np.mean(data ** 2))) or 1e-6
        if peak < 1e-4:
            print("警告：合成结果几乎静音（peak=%.5f）" % peak)
            return path
        gain = min(target_peak / peak, 8.0)
        if rms * gain < target_rms:          # 整体偏轻时再抬，但受峰值上限约束
            gain = min(gain * (target_rms / max(rms * gain, 1e-6)), 8.0)
        data = np.clip(data * gain, -1.0, 1.0)

        frame = max(1, int(sr * 0.02))
        energy = np.abs(data).max(axis=1)
        idx = np.where(energy > 0.01)[0]
        if idx.size:
            start = max(0, int(idx[0]) - frame)
            end = min(len(data), int(idx[-1]) + frame)
            data = data[start:end]

        out = str(Path(path).with_name(Path(path).stem + "_norm.wav"))
        sf.write(out, data, sr, subtype="PCM_16")
        print("响度归一：peak %.3f -> %.3f，时长 %.2fs" %
              (peak, float(np.max(np.abs(data))), len(data) / sr))
        return out
    except Exception as exc:
        print("响度归一失败（用原始音频）：", repr(exc))
        return path


def synth(text, ref_path, prompt_text):
    # top_p / temperature 设成 1（最大随机）时声音容易飘、含糊，所以给了保守默认值
    params = {
        "top_k": 20,
        "top_p": 0.6,
        "temperature": 0.6,
        "speed": 1.0,
        "sample_steps": 32,
        "pause_second": 0.3,
    }
    try:
        with open(PARAMS_JSON, encoding="utf-8") as fh:
            params.update({k: v for k, v in json.load(fh).items() if k in params})
    except Exception:
        pass

    return client.predict(
        file(ref_path),
        prompt_text,
        "中文",
        text,
        "中文",
        "按标点符号切",
        int(params["top_k"]),
        float(params["top_p"]),
        float(params["temperature"]),
        False,
        float(params["speed"]),
        False,
        None,
        int(params["sample_steps"]),
        False,
        float(params["pause_second"]),
        api_name="/get_tts_wav",
    )


os.makedirs(OUTPUT_DIR, exist_ok=True)

load_default_ref()
REFS = _load_refs()

if not os.path.isfile(REF_AUDIO):
    raise SystemExit(
        "找不到参考音频: " + REF_AUDIO + "\n"
        "请把 voice_refs/000001.ogg 放到仓库里，或用 QING_REF_AUDIO 指定路径。"
    )

print("情绪参考音频：", "、".join(sorted(REFS)) or "（未加载，用默认参考）")
print("正在连接 GPT-SoVITS:", BACKEND)
client = Client(BACKEND, verbose=False)
print("GPT-SoVITS 连接成功")


class Handler(BaseHTTPRequestHandler):

    def send_bytes(self, status, data, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path

        if path in ("/", "/health"):
            self.send_bytes(200, b"Qing TTS adapter is running", "text/plain; charset=utf-8")
        elif path == "/speakers":
            body = json.dumps([{"name": "晴小姐"}], ensure_ascii=False).encode("utf-8")
            self.send_bytes(200, body, "application/json; charset=utf-8")
        else:
            self.send_bytes(404, b"Not found", "text/plain")

    def do_POST(self):
        if urlparse(self.path).path not in ("/", "/v1/audio/speech"):
            self.send_bytes(404, b"Not found", "text/plain")
            return

        temp_result = None
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 2_000_000:
                self.send_bytes(400, b"Invalid request size", "text/plain")
                return

            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            text = str(payload.get("input", payload.get("text", ""))).strip()
            if not text:
                self.send_bytes(400, b"Text is empty", "text/plain")
                return

            # 情绪 -> 参考音频（没传情绪就用默认那条）
            emotion = str(payload.get("emotion") or payload.get("referenceId") or "").strip()
            if not emotion:
                voice = str(payload.get("voice") or "").strip()
                if voice and voice not in ("winefox", "astra-tts"):
                    emotion = voice
            ref_path, prompt_text, bucket = pick_ref(emotion)
            print("情绪:", emotion or "-", "-> 参考:", bucket, os.path.basename(ref_path))

            try:
                temp_result = synth(text, ref_path, prompt_text)
            except Exception as exc:
                if ref_path == REF_AUDIO:
                    raise
                print("换参考失败，退回默认：", repr(exc))
                temp_result = synth(text, REF_AUDIO, PROMPT_TEXT)

            if not isinstance(temp_result, str):
                raise RuntimeError("GPT-SoVITS 未返回可识别的音频文件路径")
            if not os.path.isfile(temp_result):
                raise RuntimeError("生成的音频文件不存在: " + str(temp_result))

            # 响度归一：模型会跟着参考音频的音量走
            temp_result = normalize_wav(temp_result)

            with open(temp_result, "rb") as fh:
                audio = fh.read()
            if not audio:
                raise RuntimeError("生成的音频文件为空")

            timestamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            safe_text = re.sub(r'[<>:"/\\|?*\r\n]+', "_", text)
            safe_text = safe_text[:24].strip(" ._") or "speech"
            filename = timestamp + "_" + safe_text + "_" + uuid.uuid4().hex[:6] + ".wav"
            saved_path = os.path.join(OUTPUT_DIR, filename)
            shutil.copyfile(temp_result, saved_path)

            print("语音已保存:", saved_path)
            print("音频大小:", len(audio), "bytes")
            self.send_bytes(200, audio, "audio/wav")

        except Exception as exc:
            print("TTS ERROR:", repr(exc))
            try:
                self.send_bytes(500, str(exc).encode("utf-8", errors="replace"),
                                "text/plain; charset=utf-8")
            except Exception:
                pass
        finally:
            # 只清理本次生成的临时文件，不扫描整个 Temp 目录
            if isinstance(temp_result, str) and os.path.isfile(temp_result):
                try:
                    os.remove(temp_result)
                    print("已清理本次临时音频")
                except OSError as exc:
                    print("临时音频清理失败:", repr(exc))

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.client_address[0], fmt % args))


# Windows 上 SO_REUSEADDR 允许两个进程绑定同一端口，曾导致两个适配器同时监听 9880。
# 关掉端口复用，第二个实例会直接失败退出。
ThreadingHTTPServer.allow_reuse_address = False
try:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
except OSError as exc:
    print("端口", PORT, "已被占用，适配器不会启动第二个实例:", repr(exc))
    raise SystemExit(3)

print()
print("晴小姐 TTS 适配器已启动")
print("接口地址:", "http://%s:%d" % (HOST, PORT))
print("参考音频:", REF_AUDIO)
print("音频保存目录:", OUTPUT_DIR)
print("按 Ctrl+C 可以停止适配器")
server.serve_forever()
