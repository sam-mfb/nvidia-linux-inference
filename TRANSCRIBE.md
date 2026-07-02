# Transcription Server

Diarized, speaker-tagged transcription via WhisperX (`large-v3`) and pyannote. Runs on `4090x2` (dual RTX 4090). Accepts audio or video files; returns timestamped transcripts with speaker labels.

**Cannot run at the same time as Ollama** — use `inference-mode` to switch.

- API base: `http://4090x2:8765` (Tailscale)
- Port: `8765`

---

## Server setup

### First-time install

```bash
# On 4090x2
cd ~/inference
HF_TOKEN=hf_... ./install-transcribe.sh
```

This installs the virtualenv at `/opt/transcribe/venv`, the server at `/opt/transcribe/transcribe-server.py`, and registers the systemd service.

You'll also need to accept the license terms for the two pyannote models on HuggingFace (free account required):
- https://huggingface.co/pyannote/speaker-diarization-3.1
- https://huggingface.co/pyannote/segmentation-3.0

### Switching between Ollama and transcription

```bash
inference-mode transcribe   # stop Ollama, start transcription server
inference-mode ollama       # stop transcription, start Ollama
inference-mode status       # show which is currently running
```

### Config

`/etc/transcribe/config.env` (readable by `sam`, not in this repo):

```
HF_TOKEN=hf_...
WHISPER_MODEL=large-v3      # or large-v3-turbo for ~4x faster, slightly less accurate
TRANSCRIBE_PORT=8765
```

After editing, restart the service:
```bash
sudo systemctl restart transcribe
```

### Logs

```bash
journalctl -u transcribe -f
```

### Updating the server

```bash
cd ~/inference
# edit transcribe-server.py, then:
sudo cp transcribe-server.py /opt/transcribe/transcribe-server.py
sudo systemctl restart transcribe
```

---

## Client usage

All examples use `4090x2` as the hostname (reachable from any Tailscale node).

### Submit a file

```bash
curl -X POST http://4090x2:8765/transcribe \
  -F file=@interview.mp4
```

Returns:
```json
{ "job_id": "3f8a2c1d-...", "status": "queued" }
```

**Optional parameters** (as form fields):

| Field | Type | Description |
|-------|------|-------------|
| `num_speakers` | int | Hint for diarization. Auto-detected if omitted. |
| `language` | string | ISO code (`en`, `fr`, `de`, …). Auto-detected if omitted. |

```bash
# With hints
curl -X POST http://4090x2:8765/transcribe \
  -F file=@panel.mp3 \
  -F num_speakers=4 \
  -F language=en
```

**Accepted formats:** mp3, wav, flac, m4a, ogg, mp4, mkv, mov, avi, webm, m4v, ts

### Poll for status

```bash
curl http://4090x2:8765/jobs/<job_id>
```

`status` will be one of: `queued` → `processing` → `done` | `failed`

When `done`, the response includes a `transcript` object:

```json
{
  "job_id": "3f8a2c1d-...",
  "status": "done",
  "language": "en",
  "transcript": {
    "segments": [
      {
        "start": 0.0,
        "end": 3.4,
        "text": " Yeah, let's get started.",
        "speaker": "SPEAKER_00",
        "words": [...]
      },
      ...
    ],
    "word_segments": [...]
  }
}
```

### Get a transcript in different formats

```bash
# SRT subtitles (for video players, Premiere, DaVinci, etc.)
curl "http://4090x2:8765/jobs/<job_id>?format=srt" > transcript.srt

# Plain text with speaker labels (for reading / LLM input)
curl "http://4090x2:8765/jobs/<job_id>?format=txt"

# Full JSON with word-level timestamps
curl "http://4090x2:8765/jobs/<job_id>?format=json"
```

SRT example:
```
1
00:00:00,000 --> 00:00:03,400
[SPEAKER_00] Yeah, let's get started.

2
00:00:03,800 --> 00:00:07,100
[SPEAKER_01] Sounds good. What are we covering today?
```

Text example:
```
SPEAKER_00:
Yeah, let's get started.

SPEAKER_01:
Sounds good. What are we covering today?
```

### One-liner: submit and wait

```bash
#!/usr/bin/env bash
# Usage: transcribe <file> [num_speakers]
FILE=$1
SPEAKERS=${2:-}
BASE=http://4090x2:8765

FORM="-F file=@$FILE"
[ -n "$SPEAKERS" ] && FORM="$FORM -F num_speakers=$SPEAKERS"

JOB=$(curl -sX POST $BASE/transcribe $FORM | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")
echo "Job: $JOB"

while true; do
  STATUS=$(curl -s $BASE/jobs/$JOB | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
  echo "  $STATUS"
  [ "$STATUS" = "done" ] || [ "$STATUS" = "failed" ] && break
  sleep 5
done

curl -s "$BASE/jobs/$JOB?format=txt"
```

### List recent jobs

```bash
curl http://4090x2:8765/jobs
curl "http://4090x2:8765/jobs?limit=50"
```

### Delete a job

```bash
curl -X DELETE http://4090x2:8765/jobs/<job_id>
```

### Health check

```bash
curl http://4090x2:8765/health
```

```json
{
  "status": "ok",
  "model": "large-v3",
  "models_loaded": true,
  "diarization": true,
  "queue_depth": 0
}
```

`models_loaded` is `false` for the first ~60 seconds after startup while Whisper and pyannote load into VRAM.

---

## Performance

On dual RTX 4090 (24 GB VRAM each):

| Content | Approximate time |
|---------|-----------------|
| 10-min audio, 2 speakers | ~1 min |
| 1-hour interview, 2 speakers | ~5–8 min |
| 1-hour panel, 4+ speakers | ~8–12 min |

Transcription is sequential (one job at a time). Jobs queue automatically.

`large-v3-turbo` cuts transcription time by ~4× at a small accuracy cost — change `WHISPER_MODEL` in `/etc/transcribe/config.env`.
