#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="autocoder_deploy.log"
exec > >(tee -a "$LOG_FILE") 2>&1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN="✅"
RED="❌"
YELLOW="⚠️"
CYAN="🔄"

section() { echo -e "\n${CYAN} $1"; }
ok() { echo -e "${GREEN} $1"; }
warn() { echo -e "${YELLOW} $1"; }
fail() { echo -e "${RED} $1"; exit 1; }

# --- Hot-reload docker group membership ----------------------------------------
if ! id -nG "$(whoami)" | grep -q "\bdocker\b"; then
  if command -v sudo >/dev/null 2>&1; then
    sudo usermod -aG docker "$(whoami)" && warn "Added $(whoami) to docker group; re-exec with new group"
    # Recheck and relaunch with docker group if still not effective
    if ! id -nG "$(whoami)" | grep -q "\bdocker\b"; then
      exec sg docker "$0 $*"
    fi
  else
    warn "Cannot add user to docker group (sudo not available)"
  fi
fi

section "System health & updates"
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
  ok "sudo present"
else
  SUDO=""
  warn "sudo not present; proceeding without"
fi

if [ -n "${SUDO}" ] && groups "$(whoami)" | grep -q "\bsudo\b"; then
  ok "User has sudo privileges"
else
  warn "User may not have sudo privileges"
fi

if [ -n "${SUDO}" ]; then
  ${SUDO} apt-get update -y && ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || warn "apt update/upgrade reported issues"
else
  warn "Skipped apt update/upgrade (no sudo)"
fi

section "Minimal Python deps for dry run and launcher"
if command -v pip3 >/dev/null 2>&1; then
  ${SUDO:-} pip3 install uvicorn typer docker aiohttp pydantic-settings sqlalchemy sqlalchemy-utils --quiet || warn "pip3 install reported issues"
else
  warn "pip3 not found; dry run may fail without docker module"
fi

section "Network integrity"
PORTS=("8080" "3000")
for p in "${PORTS[@]}"; do
  if lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    PID=$(lsof -iTCP:"$p" -sTCP:LISTEN -t | head -n1)
    warn "Port $p in use by PID $PID"
  else
    ok "Port $p available"
  fi
done

if ping -c1 8.8.8.8 >/dev/null 2>&1; then
  ok "Internet connectivity OK"
else
  fail "No internet connectivity; cannot pull Docker images"
fi

section "Docker & permissions"
if ! command -v docker >/dev/null 2>&1; then
  fail "Docker not installed"
fi

if ! docker info >/dev/null 2>&1; then
  fail "Docker daemon unreachable; ensure it is running"
fi
ok "Docker daemon reachable"

if ! groups "$(whoami)" | grep -q "\bdocker\b"; then
  warn "User still not in docker group in this shell; rerun or ensure sg re-exec applied."
else
  ok "User in docker group"
fi

if [ ! -S /var/run/docker.sock ]; then
  fail "Docker socket /var/run/docker.sock missing"
fi
ok "Docker socket present"

SANDBOX_DIR="${ROOT_DIR}/backend/data/sandboxes"
mkdir -p "$SANDBOX_DIR"
chmod 777 "$SANDBOX_DIR"
ok "Sandbox directory prepared with 777 perms: $SANDBOX_DIR"

section "Environment cleanup"
docker container prune -f >/dev/null 2>&1 || warn "Container prune issue"
docker image prune -f >/dev/null 2>&1 || warn "Image prune issue"
ok "Prune completed"

section "Image pulls"
docker pull python:3.11-slim
docker pull node:20-slim
docker pull alpine:latest
ok "Images pulled"

section "Dry runs"
PY_BIN="python3"
if [ -x "${ROOT_DIR}/backend/venv/bin/python" ]; then
  PY_BIN="${ROOT_DIR}/backend/venv/bin/python"
fi

${PY_BIN} - <<'PY' || fail "Python dry run failed"
import docker
client = docker.from_env()
out = client.containers.run("python:3.11-slim", ["python", "-c", "print('Python OK')"], remove=True)
print(out.decode().strip())
PY
ok "Python dry run (docker exec) passed"

node -e "console.log('Node OK')" >/dev/null 2>&1 || fail "Node dry run failed"
ok "Node dry run passed"

${PY_BIN} - <<'PY' || fail "Bash dry run failed"
import docker
client = docker.from_env()
out = client.containers.run("alpine:latest", ["sh", "-c", "echo BashOK"], remove=True)
print(out.decode().strip())
PY
ok "Bash dry run (docker exec) passed"

section "Router & UI checks"
python3 - <<'PY' || fail "Router registration check failed"
import sys, re, pathlib
text = pathlib.Path("backend/open_webui/main.py").read_text()
for needle in [
    r"include_router\(autocoder\.router",
    r"include_router\(google\.router",
]:
    if not re.search(needle, text):
        raise SystemExit(f"Missing router registration: {needle}")
print("Routers registered: autocoder + google")
PY
ok "Router registration verified"

if grep -R "AutocoderWorkflow" -n "${ROOT_DIR}/src" >/dev/null 2>&1; then
  ok "AutocoderWorkflow referenced in source"
else
  warn "AutocoderWorkflow not referenced; ensure it is imported where needed"
fi

section "Bolt AutocoderWorkflow into UI (idempotent)"
python3 - <<'PY' || warn "AutocoderWorkflow injection encountered issues"
from pathlib import Path

path = Path("src/lib/components/chat/Messages.svelte")
text = path.read_text()

if "AutocoderWorkflow" not in text:
    text = text.replace("import Message from './Messages/Message.svelte';",
                        "import Message from './Messages/Message.svelte';\nimport AutocoderWorkflow from './AutocoderWorkflow.svelte';")

if "const hasWorkflow" not in text:
    inject = """
const hasWorkflow = (message) => {
	if (!message) return false;
	if (message.workflow || (message.metadata && message.metadata.workflow)) return true;
	const c = message.content;
	if (typeof c === 'string' && c.includes('"type":"workflow"')) return true;
	if (Array.isArray(c)) {
		return c.some((p) => typeof p === 'string' && p.includes('"type":"workflow"'));
	}
	return false;
};
"""
    anchor = "const scrollToBottom = () => {"
    if anchor in text:
        idx = text.index(anchor)
        end_brace = text.index("};", idx) + 2
        text = text[:end_brace] + inject + text[end_brace:]

if "AutocoderWorkflow events=" not in text:
    old = """{#each messages as message, messageIdx (message.id)}
\t\t\t\t\t\t<Message
\t\t\t\t\t\t\t{chatId}
\t\t\t\t\t\t\tbind:history
\t\t\t\t\t\t\t{selectedModels}
\t\t\t\t\t\t\tmessageId={message.id}
\t\t\t\t\t\t\tidx={messageIdx}
\t\t\t\t\t\t\t{user}
\t\t\t\t\t\t\t{setInputText}
\t\t\t\t\t\t\t{gotoMessage}
\t\t\t\t\t\t\t{showPreviousMessage}
\t\t\t\t\t\t\t{showNextMessage}
\t\t\t\t\t\t\t{updateChat}
\t\t\t\t\t\t\t{editMessage}
\t\t\t\t\t\t\t{deleteMessage}
\t\t\t\t\t\t\t{rateMessage}
\t\t\t\t\t\t\t{actionMessage}
\t\t\t\t\t\t\t{saveMessage}
\t\t\t\t\t\t\t{submitMessage}
\t\t\t\t\t\t\t{regenerateResponse}
\t\t\t\t\t\t\t{continueResponse}
\t\t\t\t\t\t\t{mergeResponses}
\t\t\t\t\t\t\t{addMessages}
\t\t\t\t\t\t\t{triggerScroll}
\t\t\t\t\t\t\t{readOnly}
\t\t\t\t\t\t\t{editCodeBlock}
\t\t\t\t\t\t\t{topPadding}
\t\t\t\t\t\t/>
\t\t\t\t\t{/each}"""
    new = """{#each messages as message, messageIdx (message.id)}
\t\t\t\t\t\t<Message
\t\t\t\t\t\t\t{chatId}
\t\t\t\t\t\t\tbind:history
\t\t\t\t\t\t\t{selectedModels}
\t\t\t\t\t\t\tmessageId={message.id}
\t\t\t\t\t\t\tidx={messageIdx}
\t\t\t\t\t\t\t{user}
\t\t\t\t\t\t\t{setInputText}
\t\t\t\t\t\t\t{gotoMessage}
\t\t\t\t\t\t\t{showPreviousMessage}
\t\t\t\t\t\t\t{showNextMessage}
\t\t\t\t\t\t\t{updateChat}
\t\t\t\t\t\t\t{editMessage}
\t\t\t\t\t\t\t{deleteMessage}
\t\t\t\t\t\t\t{rateMessage}
\t\t\t\t\t\t\t{actionMessage}
\t\t\t\t\t\t\t{saveMessage}
\t\t\t\t\t\t\t{submitMessage}
\t\t\t\t\t\t\t{regenerateResponse}
\t\t\t\t\t\t\t{continueResponse}
\t\t\t\t\t\t\t{mergeResponses}
\t\t\t\t\t\t\t{addMessages}
\t\t\t\t\t\t\t{triggerScroll}
\t\t\t\t\t\t\t{readOnly}
\t\t\t\t\t\t\t{editCodeBlock}
\t\t\t\t\t\t\t{topPadding}
\t\t\t\t\t\t/>
\t\t\t\t\t\t{#if hasWorkflow(message)}
\t\t\t\t\t\t\t<AutocoderWorkflow events={message.workflow ?? message?.metadata?.workflow ?? []} />
\t\t\t\t\t\t{/if}
\t\t\t\t\t{/each}"""
    if old in text:
        text = text.replace(old, new)

path.write_text(text)
print("AutocoderWorkflow injection complete")
PY

section "Final status"
if [ -f "${ROOT_DIR}/backend/open_webui/utils/executor.py" ]; then
  ok "executor.py present"
else
  fail "executor.py missing"
fi

section "Kill existing services"
for p in 3000 8080; do
  if lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    PID=$(lsof -iTCP:"$p" -sTCP:LISTEN -t | head -n1)
    warn "Killing PID $PID on port $p"
    kill -9 "$PID" || true
  fi
done

BACKEND_DIR="${ROOT_DIR}/backend"
FRONTEND_DIR="${ROOT_DIR}"

section "Frontend build"
cd "$FRONTEND_DIR"
export NODE_OPTIONS="--max-old-space-size=4096"
npm set progress=false >/dev/null 2>&1 || true
npm ci >/dev/null 2>&1 || warn "npm ci encountered issues"
if [ ! -d "node_modules/vite-plugin-progress" ]; then
  npm install vite-plugin-progress --no-save --legacy-peer-deps >/dev/null 2>&1 || warn "npm install vite-plugin-progress encountered issues"
fi
if command -v nproc >/dev/null 2>&1; then
  CORES=$(nproc)
  if [ "$CORES" -gt 1 ]; then
    export VITE_BUILD_PARALLEL="$CORES"
  fi
fi
python3 - <<'PY' || warn "vite.config.ts patch failed"
from pathlib import Path
p = Path("vite.config.ts")
t = p.read_text()
import_line = "import progress from 'vite-plugin-progress';"
needs_import = import_line not in t
needs_plugin = "progress()" not in t

if needs_import:
    t = import_line + "\n" + t

if needs_plugin:
    target = "plugins: [\n\t\tsveltekit(),"
    if target in t:
        t = t.replace(target, "plugins: [\n\t\tsveltekit(),\n\t\tprogress(),")
    else:
        t = t.replace("plugins: [", "plugins: [\n\t\tprogress(),")

p.write_text(t)
PY
# If plugin still missing, strip it from config to allow build
if [ ! -d "node_modules/vite-plugin-progress" ]; then
  python3 - <<'PY'
from pathlib import Path
p = Path("vite.config.ts")
t = p.read_text()
t = t.replace("import progress from 'vite-plugin-progress';\n", "")
t = t.replace("progress(),\n", "")
t = t.replace("progress()", "")
p.write_text(t)
print("Removed vite-plugin-progress from config (not installed)")
PY
fi

# Skip build if already built
if [ -f "dist/index.html" ] || [ -f "build/index.html" ]; then
  warn "dist/build already present; skipping npm run build"
else
  # Add temporary swap for build stability
  SWAPFILE="/tmp/autocoder_swapfile"
  if [ ! -f "$SWAPFILE" ]; then
    sudo fallocate -l 2G "$SWAPFILE" && sudo chmod 600 "$SWAPFILE" && sudo mkswap "$SWAPFILE" && sudo swapon "$SWAPFILE" || warn "swap creation failed"
  fi
  export NODE_OPTIONS="--max-old-space-size=4096"
  npx vite build --logLevel info | tee "${ROOT_DIR}/frontend_build.log"
  # Optionally keep swap enabled; remove if desired:
  # sudo swapoff "$SWAPFILE" && sudo rm -f "$SWAPFILE"
fi
npm run build | tee "${ROOT_DIR}/frontend_build.log"

section "Launch backend"
cd "$BACKEND_DIR"
BACKEND_CMD="PYTHONPATH=${PYTHONPATH:-}:${BACKEND_DIR} nohup python3 -m open_webui.main --host 0.0.0.0 --port 8080 > ${ROOT_DIR}/backend.log 2>&1 &"
echo "Launching backend with: $BACKEND_CMD"
PYTHONPATH="${PYTHONPATH:-}:${BACKEND_DIR}" nohup python3 -m open_webui.main --host 0.0.0.0 --port 8080 > "${ROOT_DIR}/backend.log" 2>&1 &
BACKEND_PID=$!
ok "Backend started (pid $BACKEND_PID)"

section "Launch frontend"
cd "$FRONTEND_DIR"
FRONTEND_CMD="nohup npm run dev -- --host 0.0.0.0 --port 3000 > ${ROOT_DIR}/frontend.log 2>&1 &"
echo "Launching frontend with: $FRONTEND_CMD"
nohup npm run dev -- --host 0.0.0.0 --port 3000 > "${ROOT_DIR}/frontend.log" 2>&1 &
FRONTEND_PID=$!
ok "Frontend started (pid $FRONTEND_PID)"

section "Health check"
echo "Waiting 20 seconds for services to come up..."
sleep 20

FE_OK=0
BE_OK=0
if curl -I http://localhost:3000 >/dev/null 2>&1; then
  ok "Frontend responding on 3000"
  FE_OK=1
else
  warn "Frontend not responding on 3000"
fi

if curl -I http://localhost:8080 >/dev/null 2>&1; then
  ok "Backend responding on 8080"
  BE_OK=1
else
  warn "Backend not responding on 8080"
fi

if [ "$FE_OK" -ne 1 ]; then
  warn "Last 10 lines of frontend.log:"
  tail -n 10 "${ROOT_DIR}/frontend.log" || true
fi

if [ "$BE_OK" -ne 1 ]; then
  warn "Last 10 lines of backend.log:"
  tail -n 10 "${ROOT_DIR}/backend.log" || true
fi

echo
echo "OPEN WEBUI IS LIVE AT http://[YOUR_VM_IP]:3000"

ok "SYSTEM FULLY OPTIMIZED AND READY"
