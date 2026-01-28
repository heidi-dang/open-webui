#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo "Syncing fork..."
git pull origin main

echo "Patching AutocoderWorkflow syntax..."
sed -i 's/{\/else}/{:else}/g' src/lib/components/chat/AutocoderWorkflow.svelte || true

echo "Cleaning node modules and lock for clean Docker context..."
rm -rf node_modules package-lock.json || true

export DOCKER_BUILDKIT=1
export NODE_OPTIONS="--max-old-space-size=4096"

echo "Building docker image..."
docker build -t open-webui:heidi-dev .

echo "Stopping any existing container..."
if docker ps -a --format '{{.Names}}' | grep -q '^open-webui$'; then
  docker stop open-webui || true
  docker rm open-webui || true
fi

echo "Launching container..."
docker run -d \
  -p 3000:8080 \
  --name open-webui \
  -v open-webui-data:/app/data \
  -e GOOGLE_API_KEY="${GOOGLE_API_KEY:-}" \
  --restart always \
  open-webui:heidi-dev

echo "Done. Container 'open-webui' running on http://localhost:3000"
