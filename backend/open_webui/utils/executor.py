"""
Utility to run untrusted Python snippets inside an isolated Docker container.
"""

from __future__ import annotations

import logging
from typing import Dict

import docker
from docker.errors import APIError, ContainerError, ImageNotFound, ReadTimeout

logger = logging.getLogger(__name__)

PYTHON_IMAGE = "python:3.11-slim"
DEFAULT_TIMEOUT = 10  # seconds
MEMORY_LIMIT = "128m"


def _ensure_image(client: docker.DockerClient) -> None:
    """
    Pull the base image if it is not already available locally.
    """
    try:
        client.images.get(PYTHON_IMAGE)
    except ImageNotFound:
        client.images.pull(PYTHON_IMAGE)


def execute_python(code: str, timeout: int = DEFAULT_TIMEOUT) -> Dict[str, str | int]:
    """
    Execute Python source code inside a sandboxed Docker container.

    :param code: Python code to execute.
    :param timeout: Maximum execution time in seconds.
    :returns: dict with stdout, stderr, and exit_code.
    """
    client = docker.from_env()
    container = None
    timed_out = False
    stdout = ""
    stderr = ""
    exit_code: int | None = None

    try:
        _ensure_image(client)

        container = client.containers.run(
            PYTHON_IMAGE,
            ["python", "-c", code],
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

    if timed_out:
        stderr = (stderr + "\n" if stderr else "") + f"Execution timed out after {timeout}s."

    return {
        "stdout": stdout.strip(),
        "stderr": stderr.strip(),
        "exit_code": exit_code if exit_code is not None else -1,
    }
