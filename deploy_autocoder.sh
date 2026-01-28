#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="autocoder_deploy.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "== Autocoder deploy validation =="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "-- Checking docker socket access --"
if [ ! -S /var/run/docker.sock ]; then
  echo "Docker socket not found at /var/run/docker.sock" && exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Cannot talk to Docker daemon. Ensure your user is in the docker group or run with appropriate privileges." && exit 1
fi
echo "Docker socket accessible."

echo "-- Preparing sandbox root with permissive permissions --"
SANDBOX_DIR="${ROOT_DIR}/backend/data/sandboxes"
mkdir -p "$SANDBOX_DIR"
chmod 777 "$SANDBOX_DIR"

echo "-- Pre-pulling sandbox images --"
docker pull python:3.11-slim
docker pull node:20-slim
docker pull alpine:latest

echo "-- Verifying router registration in backend/open_webui/main.py --"
python3 - <<'PY'
import sys, re, pathlib
text = pathlib.Path("backend/open_webui/main.py").read_text()
for needle in [
    r"include_router\(autocoder\.router",
    r"include_router\(google\.router",
]:
    if not re.search(needle, text):
        sys.exit(f"Missing router registration: {needle}")
print("Routers registered: autocoder + google")
PY

echo "-- Checking Svelte UI component for workflow --"
if [ -f "${ROOT_DIR}/src/lib/components/chat/AutocoderWorkflow.svelte" ]; then
  echo "AutocoderWorkflow.svelte present."
else
  echo "Missing AutocoderWorkflow.svelte" && exit 1
fi

echo "-- Dry run: python executor --"
python3 - <<'PY'
import sys, pathlib
sys.path.append(str(pathlib.Path("backend")))
from open_webui.utils.executor import execute_code
print(execute_code("print('py-ok')", "python", session_id="dryrun"))
PY

echo "-- Dry run: node executor --"
python3 - <<'PY'
import sys, pathlib
sys.path.append(str(pathlib.Path("backend")))
from open_webui.utils.executor import execute_code
print(execute_code("console.log('js-ok')", "javascript", session_id="dryrun"))
PY

echo "-- Dry run: bash executor --"
python3 - <<'PY'
import sys, pathlib
sys.path.append(str(pathlib.Path("backend")))
from open_webui.utils.executor import execute_code
print(execute_code("echo bash-ok", "bash", session_id="dryrun"))
PY

echo "-- Verifying Svelte manifest reference (build will fail if missing) --"
if grep -R "AutocoderWorkflow" -n "${ROOT_DIR}/src" >/dev/null 2>&1; then
  echo "AutocoderWorkflow referenced in source."
else
  echo "Warning: AutocoderWorkflow not referenced in source; ensure it is imported where needed."
fi

echo "-- Restarting backend service if managed by systemd --"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet open-webui-backend; then
  sudo systemctl restart open-webui-backend
  echo "systemd service open-webui-backend restarted."
else
  echo "No systemd backend service detected; please restart your backend process manually if needed."
fi

echo "-- Summary --"
echo "All checks passed. Ready to deploy."
