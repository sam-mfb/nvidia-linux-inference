#!/usr/bin/env python3
"""
Transcription server — WhisperX + pyannote diarization.
Whisper runs on cuda:0, diarization on cuda:1.
Runs as an alternative to Ollama (systemd Conflicts=ollama.service).

API:
  POST /transcribe           upload file → {job_id, status}
  GET  /jobs/{id}            poll status; includes transcript when done
  GET  /jobs/{id}?format=srt  SRT subtitles
  GET  /jobs/{id}?format=txt  plain text with speaker labels
  GET  /jobs               list recent jobs
  DELETE /jobs/{id}        delete job + result
  GET  /health
"""

import json
import logging
import os
import shutil
import sqlite3
import subprocess
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import PlainTextResponse

# ── config ────────────────────────────────────────────────────────────────────

HF_TOKEN     = os.environ.get("HF_TOKEN", "")
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "large-v3")
PORT         = int(os.environ.get("TRANSCRIBE_PORT", "8765"))
DB_PATH      = "/var/lib/transcribe/jobs.db"
UPLOAD_DIR   = Path("/var/lib/transcribe/uploads")
RESULTS_DIR  = Path("/var/lib/transcribe/results")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

app = FastAPI(title="Transcription Server", version="1.0")

# ── model cache ───────────────────────────────────────────────────────────────

_models_loaded = False
_model_lock    = threading.Lock()
_whisper       = None
_align_cache   = {}   # lang_code -> (model_a, metadata)
_diarizer      = None


def load_models():
    global _models_loaded, _whisper, _diarizer
    import whisperx

    log.info("Loading Whisper %s on cuda:0 ...", WHISPER_MODEL)
    _whisper = whisperx.load_model(
        WHISPER_MODEL, device="cuda", device_index=0, compute_type="float16"
    )

    if HF_TOKEN:
        log.info("Loading diarization pipeline on cuda:1 ...")
        _diarizer = whisperx.DiarizationPipeline(
            use_auth_token=HF_TOKEN, device="cuda:1"
        )
    else:
        log.warning("HF_TOKEN not set — diarization disabled")

    _models_loaded = True
    log.info("Models ready")


def _preload():
    with _model_lock:
        if not _models_loaded:
            load_models()

# ── database ──────────────────────────────────────────────────────────────────

def _db():
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db():
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    conn = _db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS jobs (
            id           TEXT PRIMARY KEY,
            status       TEXT NOT NULL DEFAULT 'queued',
            filename     TEXT,
            created_at   TEXT NOT NULL,
            updated_at   TEXT NOT NULL,
            error        TEXT,
            result_path  TEXT,
            language     TEXT,
            num_speakers INTEGER
        )
    """)
    conn.commit()
    conn.close()


def _db_update(job_id: str, **kw):
    kw["updated_at"] = datetime.utcnow().isoformat()
    sets = ", ".join(f"{k}=?" for k in kw)
    vals = list(kw.values()) + [job_id]
    conn = _db()
    conn.execute(f"UPDATE jobs SET {sets} WHERE id=?", vals)
    conn.commit()
    conn.close()

# ── job processing ────────────────────────────────────────────────────────────

_queue      = []
_queue_lock = threading.Lock()
_worker     = None

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".webm", ".flv", ".m4v", ".ts"}


def _process(job_id: str, upload_path: str, num_speakers: Optional[int], language: Optional[str]):
    import whisperx

    try:
        _db_update(job_id, status="processing")

        # Extract audio if video
        ext = Path(upload_path).suffix.lower()
        if ext in VIDEO_EXTS:
            wav_path = upload_path + ".wav"
            subprocess.run(
                ["ffmpeg", "-i", upload_path, "-ar", "16000", "-ac", "1",
                 "-c:a", "pcm_s16le", wav_path, "-y"],
                check=True, capture_output=True
            )
            audio_path = wav_path
        else:
            audio_path = upload_path

        audio = whisperx.load_audio(audio_path)

        # Transcribe
        tx_kw = {"batch_size": 16}
        if language:
            tx_kw["language"] = language
        result = _whisper.transcribe(audio, **tx_kw)
        lang = result["language"]
        log.info("job %s: lang=%s segments=%d", job_id, lang, len(result["segments"]))

        # Word-level alignment (cuda:0)
        if lang not in _align_cache:
            ma, meta = whisperx.load_align_model(language_code=lang, device="cuda:0")
            _align_cache[lang] = (ma, meta)
        ma, meta = _align_cache[lang]
        result = whisperx.align(
            result["segments"], ma, meta, audio,
            device="cuda:0", return_char_alignments=False
        )

        # Diarization (cuda:1)
        if _diarizer is not None:
            d_kw = {}
            if num_speakers:
                d_kw["num_speakers"] = num_speakers
            diarize_segs = _diarizer(audio, **d_kw)
            result = whisperx.assign_word_speakers(diarize_segs, result)

        output = {
            "job_id":       job_id,
            "language":     lang,
            "segments":     result["segments"],
            "word_segments": result.get("word_segments", []),
        }

        result_path = str(RESULTS_DIR / f"{job_id}.json")
        with open(result_path, "w") as f:
            json.dump(output, f)

        _db_update(job_id, status="done", result_path=result_path, language=lang)
        log.info("job %s: done", job_id)

    except Exception as e:
        log.exception("job %s failed", job_id)
        _db_update(job_id, status="failed", error=str(e))

    finally:
        for p in [upload_path, upload_path + ".wav"]:
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def _worker_loop():
    with _model_lock:
        if not _models_loaded:
            load_models()
    while True:
        job = None
        with _queue_lock:
            if _queue:
                job = _queue.pop(0)
        if job:
            _process(*job)
        else:
            time.sleep(1)


def _enqueue(job_id: str, path: str, num_speakers: Optional[int], language: Optional[str]):
    global _worker
    with _queue_lock:
        _queue.append((job_id, path, num_speakers, language))
    if _worker is None or not _worker.is_alive():
        _worker = threading.Thread(target=_worker_loop, daemon=True)
        _worker.start()

# ── API ───────────────────────────────────────────────────────────────────────

@app.on_event("startup")
def startup():
    init_db()
    threading.Thread(target=_preload, daemon=True).start()


@app.post("/transcribe", status_code=202)
def transcribe(
    file: UploadFile = File(...),
    num_speakers: Optional[int] = Form(None),
    language: Optional[str] = Form(None),
):
    """Upload an audio or video file for transcription. Returns a job_id to poll."""
    job_id = str(uuid.uuid4())
    suffix = Path(file.filename or "audio.bin").suffix or ".bin"
    upload_path = str(UPLOAD_DIR / f"{job_id}{suffix}")

    with open(upload_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    now = datetime.utcnow().isoformat()
    conn = _db()
    conn.execute(
        "INSERT INTO jobs (id, status, filename, created_at, updated_at, num_speakers, language)"
        " VALUES (?,?,?,?,?,?,?)",
        (job_id, "queued", file.filename, now, now, num_speakers, language),
    )
    conn.commit()
    conn.close()

    _enqueue(job_id, upload_path, num_speakers, language)
    return {"job_id": job_id, "status": "queued"}


@app.get("/jobs/{job_id}")
def get_job(job_id: str, format: str = "json"):
    """
    Poll job status. When status=="done", includes the transcript.
    ?format=srt  →  SRT subtitle text
    ?format=txt  →  plain text with speaker labels
    ?format=json →  full JSON with timestamps (default)
    """
    conn = _db()
    row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(404, "Job not found")

    result = dict(row)

    if result["status"] == "done" and result.get("result_path"):
        with open(result["result_path"]) as f:
            data = json.load(f)
        if format == "srt":
            return PlainTextResponse(_to_srt(data["segments"]), media_type="text/plain")
        if format == "txt":
            return PlainTextResponse(_to_text(data["segments"]), media_type="text/plain")
        result["transcript"] = data

    return result


@app.get("/jobs")
def list_jobs(limit: int = 20):
    """List recent jobs (newest first)."""
    conn = _db()
    rows = conn.execute(
        "SELECT id, status, filename, created_at, updated_at, language"
        " FROM jobs ORDER BY created_at DESC LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


@app.delete("/jobs/{job_id}", status_code=204)
def delete_job(job_id: str):
    """Delete a job and its result file."""
    conn = _db()
    row = conn.execute("SELECT result_path FROM jobs WHERE id=?", (job_id,)).fetchone()
    if not row:
        conn.close()
        raise HTTPException(404, "Job not found")
    if row["result_path"]:
        Path(row["result_path"]).unlink(missing_ok=True)
    conn.execute("DELETE FROM jobs WHERE id=?", (job_id,))
    conn.commit()
    conn.close()


@app.get("/health")
def health():
    return {
        "status":        "ok",
        "model":         WHISPER_MODEL,
        "models_loaded": _models_loaded,
        "diarization":   _diarizer is not None,
        "queue_depth":   len(_queue),
    }

# ── output formatters ─────────────────────────────────────────────────────────

def _fmt_ts(seconds: float) -> str:
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",")


def _to_srt(segments: list) -> str:
    lines = []
    for i, seg in enumerate(segments, 1):
        speaker = f"[{seg['speaker']}] " if "speaker" in seg else ""
        lines += [
            str(i),
            f"{_fmt_ts(seg['start'])} --> {_fmt_ts(seg['end'])}",
            f"{speaker}{seg['text'].strip()}",
            "",
        ]
    return "\n".join(lines)


def _to_text(segments: list) -> str:
    parts = []
    cur_speaker = None
    for seg in segments:
        speaker = seg.get("speaker")
        text = seg["text"].strip()
        if speaker and speaker != cur_speaker:
            cur_speaker = speaker
            parts.append(f"\n{speaker}:")
        parts.append(text)
    return " ".join(parts).strip()


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
