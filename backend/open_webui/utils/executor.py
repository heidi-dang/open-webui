"""
Utility to run untrusted code snippets inside isolated Docker containers,
with per-session persistent workspaces.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Dict, Tuple

import docker
from docker.errors import APIError, ContainerError, ImageNotFound, ReadTimeout

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT = 10  # seconds
MEMORY_LIMIT = "128m"
SANDBOX_ROOT = Path("backend/data/sandboxes")

LANG_CONFIG: Dict[str, Tuple[str, list[str]]] = {
    "python": ("python:3.11-slim", ["python", "-c"]),
    "javascript": ("node:20-slim", ["node", "-e"]),
    "js": ("node:20-slim", ["node", "-e"]),
    "node": ("node:20-slim", ["node", "-e"]),
    "go": ("golang:1.21-alpine", ["sh", "-c"]),
    "bash": ("alpine:latest", ["sh", "-c"]),
    "shell": ("alpine:latest", ["sh", "-c"]),
}


def _ensure_image(client: docker.DockerClient, image: str) -> None:
    """Pull the base image if it is not already available locally."""
    try:
        client.images.get(image)
    except ImageNotFound:
        client.images.pull(image)


def execute_code(
    code: str,
    language: str = "python",
    timeout: int = DEFAULT_TIMEOUT,
    session_id: str | None = None,
) -> Dict[str, str | int]:
    """
    Execute source code inside a sandboxed Docker container with a persistent workspace.

    :param code: Source code to execute.
    :param language: Language tag (python, javascript, go, bash).
    :param timeout: Maximum execution time in seconds.
    :param session_id: Stable identifier for workspace persistence.
    :returns: dict with stdout, stderr, and exit_code.
    """
    lang = (language or "python").lower()
    image, base_cmd = LANG_CONFIG.get(lang, LANG_CONFIG["python"])

    session_name = session_id or "default"
    session_path = SANDBOX_ROOT / session_name
    session_path.mkdir(parents=True, exist_ok=True)
    try:
        session_path.chmod(0o777)
    except Exception:
        pass

    client = docker.from_env()
    container = None
    timed_out = False
    stdout = ""
    stderr = ""
    exit_code: int | None = None

    try:
        _ensure_image(client, image)

        if lang == "go":
            runner = (
                "cat <<'EOF' >/workspace/main.go\n"
                f"{code}\n"
                "EOF\n"
                "cd /workspace && go run /workspace/main.go"
            )
            cmd = ["sh", "-c", runner]
        elif lang in {"bash", "shell"}:
            cmd = ["sh", "-c", code]
        elif base_cmd[-1] == "-e":
            cmd = [*base_cmd, code]
        else:
            cmd = [*base_cmd, code]

        container = client.containers.run(
            image,
            cmd,
            detach=True,
            network_disabled=True,
            mem_limit=MEMORY_LIMIT,
            memswap=MEMORY_LIMIT,
            stdin_open=False,
            stdout=True,
            stderr=True,
            tty=False,
            user="1000:1000",
            security_opt=["no-new-privileges"],
            pids_limit=128,
            volumes={str(session_path): {"bind": "/workspace", "mode": "rw"}},
            working_dir="/workspace",
        )

        result = container.wait(timeout=timeout)
        exit_code = result.get("StatusCode", -1)

    except ReadTimeout:
        timed_out = True
        exit_code = 124
        if container:
            try:
                container.kill()
            except Exception as kill_err:  # pragma: no cover - best-effort cleanup
                logger.warning("Failed to kill timed-out container: %s", kill_err)

    except ContainerError as err:
        exit_code = err.exit_status
        stderr = str(err)

    except APIError as err:
        exit_code = -1
        stderr = f"Docker API error: {err}"

    except Exception as err:  # pragma: no cover - unexpected failures
        exit_code = -1
        stderr = f"Unhandled error: {err}"

    try:
        if container:
            stdout_bytes = container.logs(stdout=True, stderr=False)
            stderr_bytes = container.logs(stdout=False, stderr=True)
            stdout = stdout_bytes.decode("utf-8", "replace")
            stderr = (stderr + "\n" if stderr else "") + stderr_bytes.decode(
                "utf-8", "replace"
            )
    finally:
        if container:
            try:
                container.remove(force=True)
            except Exception as rm_err:  # pragma: no cover - best-effort cleanup
                logger.warning("Failed to remove container: %s", rm_err)
        try:
            client.containers.prune(filters={"status": "exited"})
        except Exception:  # pragma: no cover
            pass

    if timed_out:
        stderr = (stderr + "\n" if stderr else "") + f"Execution timed out after {timeout}s."

    return {
        "stdout": stdout.strip(),
        "stderr": stderr.strip(),
        "exit_code": exit_code if exit_code is not None else -1,
    }
