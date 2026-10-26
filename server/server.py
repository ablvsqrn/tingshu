#!/usr/bin/env python3
"""
TingShu TTS proxy server.

Runs on the user's own server (Oracle sg-free-01). The iOS app never talks to
Microsoft directly: Edge TTS's Sec-MS-GEC token algorithm changes whenever
Microsoft rotates it (v1 plain SHA-256 -> v2 obfuscated hash in 2025), so the
token logic lives here in the upstream `edge-tts` pip package, which can be
upgraded with one command and zero app rebuilds.

Endpoints:
  GET  /health            -> {"ok": true, "edge_tts": "<version>"}
  GET  /voices?lang=zh    -> filtered voice list from Microsoft
  POST /tts               -> {"text": "...", "voice": "zh-CN-XiaoxiaoNeural",
                              "rate": "+0%", "pitch": "+0Hz"}
                             returns audio/mpeg (whole utterance, buffered)

Binds 0.0.0.0:8765 by default. Intended to be reached ONLY over Tailscale
(100.70.147.99) — do not expose this port to the public internet.
"""

import asyncio
import io
import json
import os

import edge_tts
from aiohttp import web

HOST = os.environ.get("TINGSHU_HOST", "0.0.0.0")
PORT = int(os.environ.get("TINGSHU_PORT", "8765"))

# Simple in-memory cache: (text, voice, rate, pitch) -> mp3 bytes.
# A chapter listened to twice should not hit Microsoft twice.
CACHE: dict = {}
CACHE_MAX_ENTRIES = 512


async def health(_request: web.Request) -> web.Response:
    return web.json_response({"ok": True, "edge_tts": edge_tts.__version__})


async def voices(request: web.Request) -> web.Response:
    lang = request.query.get("lang", "zh")
    try:
        all_voices = await edge_tts.list_voices()
    except Exception as exc:  # Microsoft unreachable etc.
        return web.json_response({"error": str(exc)}, status=502)
    selected = [
        {
            "shortName": v["ShortName"],
            "gender": v["Gender"],
            "locale": v["Locale"],
            "friendlyName": v.get("FriendlyName", v["ShortName"]),
        }
        for v in all_voices
        if v["Locale"].lower().startswith(lang.lower())
    ]
    return web.json_response({"voices": selected})


async def synthesize(text: str, voice: str, rate: str, pitch: str):
    """Return MP3 bytes for one utterance (cached), or raise on failure."""
    key = (text, voice, rate, pitch)
    if key in CACHE:
        return CACHE[key]
    communicate = edge_tts.Communicate(text, voice, rate=rate, pitch=pitch)
    buffer = io.BytesIO()
    async for chunk in communicate.stream():
        if chunk["type"] == "audio":
            buffer.write(chunk["data"])
    data = buffer.getvalue()
    if not data:
        raise RuntimeError("empty audio from upstream")
    if len(CACHE) >= CACHE_MAX_ENTRIES:
        CACHE.pop(next(iter(CACHE)))
    CACHE[key] = data
    return data


def _check_text(text: str):
    if not text:
        return web.json_response({"error": "text is empty"}, status=400)
    if len(text) > 1800:  # edge-tts chunks internally, but keep requests sane
        return web.json_response({"error": "text too long, split into sentences"}, status=400)
    return None


async def tts(request: web.Request) -> web.Response:
    try:
        payload = await request.json()
    except Exception:
        return web.json_response({"error": "invalid JSON body"}, status=400)

    text = (payload.get("text") or "").strip()
    voice = payload.get("voice") or "zh-CN-XiaoxiaoNeural"
    rate = payload.get("rate") or "+0%"
    pitch = payload.get("pitch") or "+0Hz"
    if (err := _check_text(text)) is not None:
        return err
    try:
        data = await synthesize(text, voice, rate, pitch)
    except Exception as exc:
        return web.json_response({"error": str(exc)}, status=502)
    return web.Response(body=data, content_type="audio/mpeg")


async def tts_get(request: web.Request) -> web.Response:
    """GET variant for Legado-format custom TTS sources (e.g. iReadNote/爱阅记).

    /api/tts?text={{speakText}}&voice=zh-CN-XiaoxiaoNeural&speed={{speakSpeed}}
    Legado's speakSpeed is an integer (25 ≈ normal in most sources); when a
    plain `rate` like +20% is passed it wins over `speed`.
    """
    q = request.query
    text = (q.get("text") or "").strip()
    voice = q.get("voice") or "zh-CN-XiaoxiaoNeural"
    pitch = q.get("pitch") or "+0Hz"
    rate = q.get("rate")
    if not rate:
        speed_raw = q.get("speed")
        if speed_raw:
            try:
                pct = max(-100, min(100, (int(speed_raw) - 25) * 4))
                rate = f"{pct:+d}%"
            except ValueError:
                rate = "+0%"
        else:
            rate = "+0%"
    if (err := _check_text(text)) is not None:
        return err
    try:
        data = await synthesize(text, voice, rate, pitch)
    except Exception as exc:
        return web.json_response({"error": str(exc)}, status=502)
    return web.Response(body=data, content_type="audio/mpeg")


async def openai_speech(request: web.Request) -> web.Response:
    """OpenAI-compatible POST /v1/audio/speech.

    Body: {"model": "...", "input": "text", "voice": "zh-CN-XiaoxiaoNeural",
           "speed": 1.0, "response_format": "mp3"}
    For readers that support a custom OpenAI-compatible TTS service
    (Readest added this in 0.12.16; kept here so any client that speaks
    this shape can use the proxy). Voice names pass straight through to
    Edge TTS; OpenAI's own voice names are mapped to a close Edge voice.
    """
    try:
        payload = await request.json()
    except Exception:
        return web.json_response({"error": "invalid JSON body"}, status=400)
    text = (payload.get("input") or "").strip()
    voice = payload.get("voice") or "zh-CN-XiaoxiaoNeural"
    voice_map = {
        "alloy": "zh-CN-XiaoxiaoNeural", "echo": "zh-CN-YunyangNeural",
        "fable": "zh-CN-YunjianNeural", "onyx": "zh-CN-YunjianNeural",
        "nova": "zh-CN-XiaoyiNeural", "shimmer": "zh-CN-XiaoyiNeural",
    }
    voice = voice_map.get(voice, voice)
    try:
        speed = float(payload.get("speed") or 1.0)
    except (TypeError, ValueError):
        speed = 1.0
    pct = max(-100, min(100, round((speed - 1.0) * 100)))
    rate = f"{pct:+d}%"
    if (err := _check_text(text)) is not None:
        return err
    try:
        data = await synthesize(text, voice, rate, "+0Hz")
    except Exception as exc:
        return web.json_response({"error": str(exc)}, status=502)
    return web.Response(body=data, content_type="audio/mpeg")


def make_app() -> web.Application:
    app = web.Application(client_max_size=64 * 1024)
    app.router.add_get("/health", health)
    app.router.add_get("/voices", voices)
    app.router.add_post("/tts", tts)
    app.router.add_get("/api/tts", tts_get)
    app.router.add_get("/tts", tts_get)
    app.router.add_post("/v1/audio/speech", openai_speech)
    return app


if __name__ == "__main__":
    web.run_app(make_app(), host=HOST, port=PORT)
