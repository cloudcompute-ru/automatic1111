#!/usr/bin/env bash
#
# Provision script for AUTOMATIC1111 WebUI (slug: automatic1111).
# Stage IDs must match config/applications.php: verify_cuda, download_model, start_server.
#
set -Eeuo pipefail

CC_PROVISION_URL="${CC_PROVISION_URL:-}"
CC_AGENT_TOKEN="${CC_AGENT_TOKEN:-}"
WEBUI_PORT="${WEBUI_PORT:-7860}"
MODEL_FILE="${MODEL_FILE:-/workspace/stable-diffusion-webui/models/Stable-diffusion/v1-5-pruned-emaonly.safetensors}"
MODEL_URL="${MODEL_URL:-https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors}"
CURRENT_STAGE=""

report_stage() {
    if [ -z "$CC_PROVISION_URL" ] || [ -z "$CC_AGENT_TOKEN" ]; then
        return 0
    fi
    curl -fsS -X POST "$CC_PROVISION_URL" \
        -H "Authorization: Bearer $CC_AGENT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$1" --max-time 5 >/dev/null 2>&1 || true
}

log() { echo "[cc-provision] $*"; }

send_log_tail() {
    if [ -z "$CC_PROVISION_URL" ] || [ -z "$CC_AGENT_TOKEN" ]; then return 0; fi
    local encoded
    encoded="$(tail -n 200 /var/log/cc-provision.log 2>/dev/null \
        | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)" || return 0
    [ -z "$encoded" ] && return 0
    report_stage "{\"stage\":\"${CURRENT_STAGE}\",\"log_tail\":${encoded}}"
}

resolve_webui_dir() {
    if [ -n "${WEBUI_DIR:-}" ] && [ -f "${WEBUI_DIR}/webui.sh" ]; then
        echo "$WEBUI_DIR"
        return 0
    fi
    local d
    for d in /workspace/stable-diffusion-webui /root/stable-diffusion-webui /opt/stable-diffusion-webui; do
        if [ -f "$d/webui.sh" ]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

# --- verify_cuda -----------------------------------------------------------

CURRENT_STAGE="verify_cuda"
log "stage: verify_cuda"
report_stage '{"stage":"verify_cuda"}'

set +e
cuda_out="$(python3 - <<'PY' 2>&1
import sys
import torch
print(f"torch={torch.__version__} cuda={torch.version.cuda}", flush=True)
if not torch.cuda.is_available():
    sys.exit(1)
print(torch.cuda.get_device_name(0), flush=True)
PY
)"
cuda_rc=$?
set -e
log "$cuda_out"
if [ "$cuda_rc" -ne 0 ]; then
    send_log_tail
    report_stage '{"stage":"verify_cuda","message":"PyTorch CUDA unavailable on this host."}'
    exit 1
fi
send_log_tail

WEBUI_DIR="$(resolve_webui_dir)" || {
    log "webui.sh not found; cloning AUTOMATIC1111 into /workspace/stable-diffusion-webui"
    mkdir -p /workspace
    if [ ! -d /workspace/stable-diffusion-webui/.git ]; then
        git clone --depth=1 https://github.com/AUTOMATIC1111/stable-diffusion-webui.git /workspace/stable-diffusion-webui
    fi
    WEBUI_DIR="/workspace/stable-diffusion-webui"
}
export WEBUI_DIR
MODEL_FILE="${WEBUI_DIR}/models/Stable-diffusion/v1-5-pruned-emaonly.safetensors"

# --- download_model --------------------------------------------------------

CURRENT_STAGE="download_model"
log "stage: download_model"
report_stage '{"stage":"download_model","progress_pct":0}'

mkdir -p "$(dirname "$MODEL_FILE")"
if [ -f "$MODEL_FILE" ] && [ "$(stat -c%s "$MODEL_FILE" 2>/dev/null || echo 0)" -gt 100000000 ]; then
    log "SD 1.5 checkpoint already present"
    report_stage '{"stage":"download_model","progress_pct":100}'
else
    if ! wget --tries=3 --timeout=120 -O "${MODEL_FILE}.partial" "$MODEL_URL"; then
        send_log_tail
        report_stage '{"stage":"download_model","message":"Failed to download SD 1.5 checkpoint."}'
        exit 1
    fi
    mv "${MODEL_FILE}.partial" "$MODEL_FILE"
    report_stage '{"stage":"download_model","progress_pct":100}'
fi
send_log_tail

# --- start_server ----------------------------------------------------------

CURRENT_STAGE="start_server"
log "stage: start_server"
report_stage '{"stage":"start_server"}'

cd "$WEBUI_DIR"
nohup bash webui.sh --listen --port "$WEBUI_PORT" --skip-prepare-environment \
    > /var/log/cc-a1111.log 2>&1 &
WEBUI_PID=$!

BIND_TIMEOUT_S=120
for _ in $(seq 1 "$BIND_TIMEOUT_S"); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${WEBUI_PORT}/" >/dev/null 2>&1; then
        send_log_tail
        report_stage "{\"stage\":\"start_server\",\"progress_pct\":100}"
        log "provisioning complete"
        exit 0
    fi
    if ! kill -0 "$WEBUI_PID" 2>/dev/null; then
        tail_msg="$(tail -c 500 /var/log/cc-a1111.log 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')"
        send_log_tail
        report_stage "{\"stage\":\"start_server\",\"message\":\"WebUI exited before ready: ${tail_msg}\"}"
        exit 1
    fi
    sleep 1
done

report_stage "{\"stage\":\"start_server\",\"message\":\"WebUI did not become ready in ${BIND_TIMEOUT_S}s.\"}"
exit 1
