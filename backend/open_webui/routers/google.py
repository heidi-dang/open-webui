import json
import os
import logging
from typing import Optional, AsyncIterable

import aiohttp
import anyio
import google.generativeai as genai
from fastapi import APIRouter, HTTPException, Request, Depends
from fastapi.responses import StreamingResponse, JSONResponse

from open_webui.utils.auth import get_verified_user
from open_webui.routers.chats import autocoder_stream_handler

log = logging.getLogger(__name__)

router = APIRouter()


def _get_api_key() -> str:
    key = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
    if not key:
        raise RuntimeError("GEMINI_API_KEY is not configured")
    return key


async def _gemini_stream(model_name: str, prompt: str) -> AsyncIterable[bytes]:
    """
    Async generator that yields SSE-style data lines from Gemini streaming output.
    """
    api_key = _get_api_key()
    genai.configure(api_key=api_key)
    model = genai.GenerativeModel(model_name)

    def sync_iter():
        return model.generate_content(prompt, stream=True)

    # Iterate in a worker thread to avoid blocking the event loop
    stream = await anyio.to_thread.run_sync(sync_iter)

    for chunk in stream:
        texts = []
        try:
            parts = chunk.candidates[0].content.parts
            for part in parts:
                if hasattr(part, "text"):
                    texts.append(part.text)
                elif isinstance(part, dict) and "text" in part:
                    texts.append(part["text"])
        except Exception:
            continue

        if not texts:
            continue

        payload = {"candidates": [{"content": {"parts": [{"text": "".join(texts)}]}}]}
        yield f"data: {json.dumps(payload)}".encode("utf-8") + b"\n\n"

    yield b"data: [DONE]\n\n"


@router.post("/chat/completions")
async def gemini_chat_completions(request: Request, body: dict, user=Depends(get_verified_user)):
    """
    Minimal Gemini chat proxy with Autocoder workflow wrapping.
    Expects body containing 'model' and 'messages'; concatenates user/assistant
    messages into a single prompt for Gemini.
    """
    model_name = body.get("model") or "gemini-pro"
    messages = body.get("messages") or []
    if not isinstance(messages, list):
        raise HTTPException(status_code=400, detail="Invalid messages format")

    prompt_parts = []
    for msg in messages:
        content = msg.get("content")
        if isinstance(content, str):
            prompt_parts.append(content)
        elif isinstance(content, list):
            for part in content:
                if isinstance(part, str):
                    prompt_parts.append(part)
                elif isinstance(part, dict) and part.get("text"):
                    prompt_parts.append(part["text"])
    prompt = "\n".join(prompt_parts)

    try:
        stream = _gemini_stream(model_name, prompt)
        return StreamingResponse(
            autocoder_stream_handler(
                stream,
                request=request,
                model_id=model_name,
                session_id=request.headers.get("X-OpenWebUI-Chat-Id"),
            ),
            media_type="text/event-stream",
        )
    except Exception as e:
        log.exception(e)
        return JSONResponse(status_code=500, content={"error": str(e)})
