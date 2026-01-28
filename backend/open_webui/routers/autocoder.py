from fastapi import APIRouter, Depends
from pydantic import BaseModel

from open_webui.utils.executor import execute_code
from open_webui.utils.auth import get_verified_user


router = APIRouter()


class CodeRequest(BaseModel):
    code: str
    language: str | None = "python"


@router.post("/verify")
async def verify_code(request: CodeRequest, user=Depends(get_verified_user)):
    """
    Execute provided code snippet inside the sandboxed executor.
    This endpoint is intended for internal agent workflow calls.
    """
    # Optionally, user dependency keeps request tied to authenticated sessions.
    result = execute_code(request.code, request.language or "python")
    return result
