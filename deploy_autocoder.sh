#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="autocoder_deploy.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "== Autocoder deploy validation =="

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
if [ -f "src/lib/components/chat/AutocoderWorkflow.svelte" ]; then
  echo "AutocoderWorkflow.svelte present."
else
  echo "Missing AutocoderWorkflow.svelte" && exit 1
fi

echo "-- Summary --"
echo "All checks passed. Ready to deploy."
