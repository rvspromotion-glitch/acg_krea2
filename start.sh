#!/usr/bin/env bash
set -euo pipefail

STARTUP_START=$(date +%s)

echo "==================================="
echo "Starting ComfyUI Setup (KREA2 + SeedVR2)"
echo "==================================="

# Fix DNS resolution issues
echo "[network] Checking DNS configuration..."
if ! grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null; then
  echo "[network] Adding Google DNS..."
  {
    echo "nameserver 8.8.8.8"
    echo "nameserver 8.8.4.4"
    echo "nameserver 1.1.1.1"
  } >> /etc/resolv.conf
fi

# Wait for network readiness
echo "[network] Waiting for network..."
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && \
     (getent hosts pypi.org >/dev/null 2>&1 || nslookup pypi.org >/dev/null 2>&1); then
    echo "[network] Network ready!"
    break
  fi
  WAIT_COUNT=$((WAIT_COUNT + 1))
  [ $WAIT_COUNT -lt $MAX_WAIT ] && sleep 1
done

COMFY_DIR="${COMFYUI_PATH:-/workspace/ComfyUI}"
CUSTOM_NODES="${COMFY_DIR}/custom_nodes"
MODELS_DIR="${COMFY_DIR}/models"
PERSIST_DIR="${RUNPOD_VOLUME:-/workspace/runpod-slim}"
BAKED_DIR="${COMFYUI_BAKED:-/opt/ComfyUI}"

mkdir -p "$(dirname "$COMFY_DIR")" "$PERSIST_DIR"

# Restore ComfyUI from baked if needed
if [ ! -f "${COMFY_DIR}/main.py" ] && [ -f "${BAKED_DIR}/main.py" ]; then
  echo "[setup] Restoring ComfyUI from baked image..."
  rm -rf "${COMFY_DIR}"
  cp -a "${BAKED_DIR}" "${COMFY_DIR}"
fi

if [ ! -f "${COMFY_DIR}/main.py" ]; then
  echo "[fatal] ComfyUI not found!"
  exit 1
fi

mkdir -p "${CUSTOM_NODES}" "${MODELS_DIR}"

# Persistent pip cache
export PIP_CACHE_DIR="${PERSIST_DIR}/.cache/pip"
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
mkdir -p "$PIP_CACHE_DIR"

# Hard constraints
CONSTRAINTS_FILE="${PERSIST_DIR}/pip-constraints.txt"
cat > "$CONSTRAINTS_FILE" <<'EOF'
numpy<2
protobuf<5
opencv-python<4.12
transformers>=4.39.3
mediapipe==0.10.14
sageattention
EOF

export PIP_CONSTRAINT="$CONSTRAINTS_FILE"

# Only install if versions are wrong (skip if already correct)
SKIP_PIP_INSTALL=0
python3 - <<'PY' && SKIP_PIP_INSTALL=1 || true
import sys
try:
    import numpy
    import mediapipe
    assert numpy.__version__.startswith('1.')
    assert mediapipe.__version__ == '0.10.14'
    sys.exit(0)
except:
    sys.exit(1)
PY

if [ "$SKIP_PIP_INSTALL" = "0" ]; then
  echo "[pip] Installing core dependencies..."
  pip install -q --upgrade --prefer-binary --retries 5 --timeout 60 \
    -c "$CONSTRAINTS_FILE" \
    "numpy<2" "protobuf<5" "opencv-python<4.12" \
    "mediapipe==0.10.14" "sageattention" || true
else
  echo "[pip] Core dependencies already correct, skipping"
fi

echo "[debug] Versions:"
python3 - <<'PY'
import torch
print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
import numpy
print("numpy:", numpy.__version__)
try:
    import mediapipe
    print("mediapipe:", mediapipe.__version__)
except:
    print("mediapipe: not installed")
PY

# Map RunPod secret to CIVITAI_TOKEN if not already set
if [ -z "${CIVITAI_TOKEN:-}" ] && [ -n "${RUNPOD_SECRET_CivitKey:-}" ]; then
  export CIVITAI_TOKEN="${RUNPOD_SECRET_CivitKey}"
  echo "[config] Using RunPod CivitAI API key"
fi

# Helpers
download() {
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  if [ -f "$out" ] && [ -s "$out" ]; then
    echo "[models] exists: $out"
    return 0
  fi
  echo "[models] downloading: $out"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -c -x 16 -s 16 -k 1M \
      --allow-overwrite=true \
      --file-allocation=none \
      --max-tries=8 \
      --retry-wait=2 \
      --timeout=60 \
      --max-connection-per-server=16 \
      --min-split-size=1M \
      -d "$(dirname "$out")" -o "$(basename "$out")" \
      "$url" 2>&1 | grep -v "^Download Results:" || true
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 8 --retry-delay 2 --max-time 300 -C - -o "$out" "$url"
  else
    wget -c -O "$out" "$url"
  fi
}

civit_download() {
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  if [ -f "$out" ] && [ -s "$out" ]; then
    echo "[civitai] exists: $out"
    return 0
  fi
  echo "[civitai] downloading: $out"
  if command -v aria2c >/dev/null 2>&1; then
    # If we have a token, get the signed redirect URL first (R2 signed URLs fail with extra headers)
    local download_url="$url"
    if [ -n "${CIVITAI_TOKEN:-}" ]; then
      echo "[civitai] Getting signed download URL..."
      download_url=$(curl -sL -I -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        -H "Authorization: Bearer ${CIVITAI_TOKEN}" \
        "$url" | grep -i "^location:" | tail -1 | sed 's/^location: //i' | tr -d '\r\n')
      if [ -z "$download_url" ]; then
        echo "[civitai] Failed to get redirect URL, using original"
        download_url="$url"
      fi
    fi
    local aria_opts=(
      -c -x 16 -s 16 -k 1M
      --allow-overwrite=true
      --file-allocation=none
      --max-tries=10
      --retry-wait=2
      --connect-timeout=30
      --timeout=60
      --max-connection-per-server=16
      --min-split-size=1M
      --split=16
      --stream-piece-selector=geom
      --optimize-concurrent-downloads=true
      --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
      -d "$(dirname "$out")" -o "$(basename "$out")"
    )
    aria2c "${aria_opts[@]}" "$download_url"
  else
    local header=()
    if [ -n "${CIVITAI_TOKEN:-}" ]; then
      header+=( -H "Authorization: Bearer ${CIVITAI_TOKEN}" )
    fi
    curl -L --fail --retry 10 --retry-delay 2 -C - \
      -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
      "${header[@]}" \
      -o "$out" "$url"
  fi
  # If we got HTML (login page), delete it so you dont think its a model
  if command -v file >/dev/null 2>&1 && file "$out" | grep -qi "HTML"; then
    echo "[civitai] ERROR: got HTML instead of model (token missing/invalid/gated). Removing $out"
    rm -f "$out"
    return 1
  fi
}

# Multi-file HF repo snapshot (for repos like krea/Krea-2-Raw that ship as
# transformer/vae/text_encoder/tokenizer subfolders instead of one file).
# Skips re-downloading if the target dir already has content.
hf_snapshot() {
  local repo="$1"
  local out_dir="$2"
  if [ -d "$out_dir" ] && [ -n "$(ls -A "$out_dir" 2>/dev/null)" ]; then
    echo "[hf] exists: $out_dir"
    return 0
  fi
  echo "[hf] snapshot downloading: $repo -> $out_dir"
  mkdir -p "$out_dir"
  huggingface-cli download "$repo" --local-dir "$out_dir" --exclude "*.md" "*.pdf" "images/*" \
    || echo "[hf] WARNING: snapshot download failed for $repo, continuing"
}

safe_pip_install_req() {
  local req="$1"
  [ -f "$req" ] || return 0
  local tmpreq
  tmpreq="$(mktemp)"
  grep -viE '^(torch|torchvision|torchaudio|numpy|transformers|tokenizers|protobuf)([<=> ].*)?$' "$req" > "$tmpreq" || true
  pip install -q --prefer-binary --retries 5 --timeout 60 -c "$CONSTRAINTS_FILE" -r "$tmpreq" 2>/dev/null || true
  rm -f "$tmpreq"
}

# Model directories
mkdir -p \
  "${MODELS_DIR}/checkpoints" \
  "${MODELS_DIR}/clip" \
  "${MODELS_DIR}/clip_vision" \
  "${MODELS_DIR}/diffusion_models" \
  "${MODELS_DIR}/loras" \
  "${MODELS_DIR}/vae" \
  "${MODELS_DIR}/SeedVR2" \
  "${MODELS_DIR}/krea2_raw"

# Cache custom nodes on persistent volume
REPO_CACHE="${PERSIST_DIR}/_repos"
mkdir -p "$REPO_CACHE"
UPDATE_NODES="${UPDATE_NODES:-0}"

# Clone ALL nodes in parallel (not batches!)
echo "[nodes] Cloning custom nodes (fully parallel)..."
(
  cd "$REPO_CACHE"

  for repo in \
    "ComfyUI-Manager:https://github.com/Comfy-Org/ComfyUI-Manager.git" \
    "rgthree-comfy:https://github.com/rgthree/rgthree-comfy.git" \
    "ComfyUI-Easy-Use:https://github.com/yolain/ComfyUI-Easy-Use.git" \
    "ComfyUI_LayerStyle:https://github.com/chflame163/ComfyUI_LayerStyle.git" \
    "ComfyUI-SeedVR2_VideoUpscaler:https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git" \
    "ComfyUI-GridSplit:https://github.com/workordie/ComfyUI-GridSplit.git" \
    "BatchnodeI9:https://github.com/rvspromotion-glitch/BatchnodeI9.git" \
    "savezipi9:https://github.com/rvspromotion-glitch/savezipi9.git"
  do
    name="${repo%%:*}"
    url="${repo#*:}"
    (
      if [ ! -d "${name}/.git" ]; then
        echo "[nodes] cloning ${name}..."
        GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true git \
          -c http.extraHeader= \
          -c credential.helper= \
          -c core.askPass= \
          clone --depth 1 --progress "$url" "$name" 2>&1 | grep -v "Checking out files" || true
      elif [ "$UPDATE_NODES" = "1" ]; then
        echo "[nodes] updating ${name}..."
        git -C "$name" pull --rebase 2>/dev/null || true
      fi
    ) &
  done
  wait

  # ComfyUI-GridSplit: workflow was built against a specific commit, pin it
  if [ -d "ComfyUI-GridSplit/.git" ]; then
    (
      cd ComfyUI-GridSplit
      if ! git cat-file -e b9941964ff879487aa3e9433b174548039748453 2>/dev/null; then
        git fetch --depth 1 origin b9941964ff879487aa3e9433b174548039748453 2>/dev/null || true
      fi
      git checkout -q b9941964ff879487aa3e9433b174548039748453 2>/dev/null \
        || echo "[nodes] WARNING: could not pin ComfyUI-GridSplit to expected commit, using latest"
    )
  fi
)

echo "[nodes] Creating symlinks..."
for dir in "${REPO_CACHE}"/*; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  case "$name" in
    savezipi9)
      # This repo ships as subpackages, not a single node dir
      for sub in "$dir"/*; do
        [ -d "$sub" ] || continue
        ln -sfn "$sub" "${CUSTOM_NODES}/$(basename "$sub")"
      done
      ;;
    *)
      ln -sfn "$dir" "${CUSTOM_NODES}/${name}"
      ;;
  esac
done

echo "[nodes] All nodes ready!"

# Download models in parallel
echo "[models] Downloading models (fully parallel)..."

# Krea2 Turbo — native krea-ai format, single checkpoint file
download "https://huggingface.co/krea/Krea-2-Turbo/resolve/main/turbo.safetensors" \
  "${MODELS_DIR}/diffusion_models/krea2_turbo.safetensors" &

# CivitAI LoRAs (fully parallel alongside the HF downloads above)
civit_download "https://civitai.red/api/download/models/3104629?fileId=2984442" \
  "${MODELS_DIR}/loras/SNOFS.safetensors" &

civit_download "https://civitai.red/api/download/models/3075498?fileId=2954554" \
  "${MODELS_DIR}/loras/NiceGirls_Ultrarealistic.safetensors" &

civit_download "https://civitai.red/api/download/models/3067151?fileId=2945865" \
  "${MODELS_DIR}/loras/Krea2_filter_bypass.safetensors" &

civit_download "https://civitai.red/api/download/models/3070702?fileId=2949534" \
  "${MODELS_DIR}/loras/Realism_engine.safetensors" &

civit_download "https://civitai.red/api/download/models/3075606?fileId=2954661" \
  "${MODELS_DIR}/loras/Lenovo_ultrareal.safetensors" &

# CivitAI checkpoints
civit_download "https://civitai.red/api/download/models/3083062?fileId=2962388" \
  "${MODELS_DIR}/checkpoints/Mystic.safetensors" &

wait
echo "[models] Single-file downloads completed!"

# Krea2 Raw — ships as a multi-file diffusers repo (transformer/vae/text_encoder/
# tokenizer/scheduler), so it needs a full snapshot rather than one URL.
# Note: this is the *native* krea-ai layout, not ComfyUI's split diffusion_models/
# + text_encoders/ + vae/ format. If the workflow's UNETLoader/CLIPLoader/VAELoader
# nodes can't read these files directly, grab the repackaged versions from
# Comfy-Org/Krea-2 instead (krea2_turbo_fp8_scaled.safetensors, qwen3vl_4b text
# encoder, qwen_image_vae.safetensors) — ask and I'll wire that in.
hf_snapshot "krea/Krea-2-Raw" "${MODELS_DIR}/krea2_raw"

# SeedVR2 DiT/VAE weights: numz/ComfyUI-SeedVR2_VideoUpscaler auto-downloads
# these itself into models/SeedVR2/ the first time the node runs — nothing to
# script here, this dir just needs to exist and be persistent (already created above).

echo "[models] All model setup done!"

# Character LoRA from env var (unchanged pattern)
if [ -n "${CHAR_LORA_URL:-}" ]; then
  echo "[models] Downloading character LoRA..."
  CHAR_LORA_FILENAME=$(basename "$CHAR_LORA_URL" | sed 's/\?.*$//')
  [ -z "$CHAR_LORA_FILENAME" ] && CHAR_LORA_FILENAME="character_lora.safetensors"
  download "$CHAR_LORA_URL" "${MODELS_DIR}/loras/${CHAR_LORA_FILENAME}"
fi

# Install node requirements (only once)
INSTALL_NODE_REQS="${INSTALL_NODE_REQS:-1}"
REQ_MARK="${PERSIST_DIR}/.node-reqs-installed"

if [ "$INSTALL_NODE_REQS" = "1" ]; then
  if [ ! -f "$REQ_MARK" ] || [ "$UPDATE_NODES" = "1" ]; then
    echo "[pip] Installing node requirements (once)..."
    for dir in "${REPO_CACHE}"/*; do
      [ -d "$dir" ] || continue
      req="${dir}/requirements.txt"
      if [ -f "$req" ]; then
        echo "  - $(basename "$dir")/requirements.txt"
        safe_pip_install_req "$req"
      fi
      # savezipi9 ships subpackages, check each for its own requirements.txt
      if [ "$(basename "$dir")" = "savezipi9" ]; then
        for subdir in "$dir"/*; do
          [ -d "$subdir" ] || continue
          req="${subdir}/requirements.txt"
          if [ -f "$req" ]; then
            echo "  - savezipi9/$(basename "$subdir")/requirements.txt"
            safe_pip_install_req "$req"
          fi
        done
      fi
    done
    touch "$REQ_MARK"
  else
    echo "[pip] Node requirements already installed (skip)"
  fi
fi

# Final safety check
pip install -q --upgrade --prefer-binary --retries 5 --timeout 60 \
  -c "$CONSTRAINTS_FILE" "numpy<2" "mediapipe==0.10.14" 2>/dev/null || true

# Start JupyterLab
echo "[jupyter] Starting JupyterLab..."
jupyter lab \
  --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
  --ServerApp.token='' --ServerApp.password='' \
  --ServerApp.allow_origin='*' \
  --ServerApp.root_dir="${COMFY_DIR}" \
  >/workspace/jupyter.log 2>&1 &

echo "==================================="
echo "Launching ComfyUI"
echo "==================================="

STARTUP_END=$(date +%s)
STARTUP_DURATION=$((STARTUP_END - STARTUP_START))
echo "[startup] Total startup time: ${STARTUP_DURATION}s"
echo "==================================="

cd "${COMFY_DIR}"
exec python3 main.py --listen 0.0.0.0 --port 8188
