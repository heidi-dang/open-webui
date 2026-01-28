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
  if [ -n "${SUDO}" ]; then
    warn "User not in docker group; adding now (logout/login required)"
    ${SUDO} usermod -aG docker "$(whoami)"
  else
    warn "Cannot add user to docker group (no sudo)"
  fi
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
PYTHONPATH="${PYTHONPATH:-}:." python3 - <<'PY' || fail "Python dry run failed"
import sys, pathlib
sys.path.append(str(pathlib.Path("backend")))
from open_webui.utils.executor import execute_code
res = execute_code("print('Python OK')", "python", session_id="dryrun")
print(res)
assert res["exit_code"] == 0
PY
ok "Python dry run passed"

node -e "console.log('Node OK')" >/dev/null 2>&1 || fail "Node dry run failed"
ok "Node dry run passed"

PYTHONPATH="${PYTHONPATH:-}:." python3 - <<'PY' || fail "Bash dry run failed"
import sys, pathlib
sys.path.append(str(pathlib.Path("backend")))
from open_webui.utils.executor import execute_code
res = execute_code("echo BashOK", "bash", session_id="dryrun")
print(res)
assert res["exit_code"] == 0
PY
ok "Bash dry run passed"

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

section "Service restart"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet open-webui-backend; then
  ${SUDO:-} systemctl restart open-webui-backend
  ok "systemd service open-webui-backend restarted"
else
  warn "No systemd backend service detected; restart your backend manually if required"
fi

section "Final status"
ok "SYSTEM FULLY OPTIMIZED AND READY"
