"""fernsprecher-ki-modus-an Whisper worker: keeps the model loaded and transcribes one WAV per stdin line.

Input line:  {"path": "/tmp/x.wav", "language": "de", "prompt": "A FaceTime call. Names: Claude, GPT."}
Output line: {"text": "...", "seconds": 0.42}   or   {"error": "..."}
"""
import json
import os
import sys
import time

import mlx_whisper

MODEL = os.environ.get("FTK_WHISPER_MODEL", os.path.join(os.path.dirname(__file__), "models", "whisper-large-v3-turbo"))

# Warm up once so the first real phrase is fast.
import numpy as np
mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo=MODEL, language="en")
print(json.dumps({"ready": True}), flush=True)

import wave


def load(path):
    # 16 kHz mono s16 WAV, which is what the CLI writes (no ffmpeg needed).
    with wave.open(path, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, "need 16 kHz mono s16"
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0


import re

# Whisper "hears" subtitle credits and outro lines in silence or noise (it was trained on subtitled video).
HALLUCINATIONS = re.compile(
    r"(subtitles by|thanks for watching|please subscribe|amara\.org|"
    r"untertitel (im auftrag|von|der)|vielen dank fürs zuschauen|"
    r"sous-titr|merci d'avoir regardé|tekstet af|tak fordi du så|"
    r"ご視聴ありがとうございました|チャンネル登録)",
    re.IGNORECASE,
)


for line in sys.stdin:
    try:
        req = json.loads(line)
        t0 = time.time()
        r = mlx_whisper.transcribe(
            load(req["path"]),
            path_or_hf_repo=MODEL,
            language=req.get("language") or None,
            initial_prompt=req.get("prompt") or None,
            condition_on_previous_text=False,
            no_speech_threshold=0.6,
            temperature=0.0,
        )
        segs = [s for s in r.get("segments", [])
                if s.get("no_speech_prob", 0) < 0.6 and not HALLUCINATIONS.search(s.get("text", ""))]
        text = " ".join(s["text"].strip() for s in segs).strip()
        print(json.dumps({"text": text, "seconds": round(time.time() - t0, 2)}, ensure_ascii=False), flush=True)
    except Exception as e:  # keep serving
        print(json.dumps({"error": repr(e)}), flush=True)
