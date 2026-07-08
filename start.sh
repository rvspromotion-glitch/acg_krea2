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

# Map RunPod secret to HF_TOKEN if not already set. Krea2 (both the original
# krea/* repos and the Comfy-Org/Krea-2 repackage) sits under Krea's custom
# community license, which HF treats as gated — you must be logged into an
# account that's clicked "agree" on the model page, and `hf download` needs
# HF_TOKEN in the environment to authenticate as that account.
if [ -z "${HF_TOKEN:-}" ] && [ -n "${RUNPOD_SECRET_HF_TOKEN:-}" ]; then
  export HF_TOKEN="${RUNPOD_SECRET_HF_TOKEN}"
  echo "[config] Using RunPod HuggingFace token"
fi

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

# hf_xet is the current (2026) accelerated transfer backend for HF downloads —
# it's used automatically by a recent huggingface_hub, no env var needed to
# turn it on. HF_XET_HIGH_PERFORMANCE=1 pushes it further (more concurrent
# connections/higher throughput mode). The old HF_HUB_ENABLE_HF_TRANSFER var
# is deprecated and does nothing anymore.
pip install -q -U "huggingface_hub[hf_xet]" --break-system-packages 2>/dev/null || true
export HF_XET_HIGH_PERFORMANCE=1

# Single-file HF download via the `hf` CLI (huggingface-cli is deprecated and
# no longer actually downloads anything — it just prints a warning and exits,
# which is why the model files silently never showed up last run). `hf` is
# the only client that gets the hf_xet acceleration. Any file living on HF —
# gated or public — should go through this, not aria2c/curl: it's consistently
# faster thanks to Xet chunked transfer.
hf_download() {
  local repo="$1"
  local remote_path="$2"   # e.g. "diffusion_models/krea2_turbo_fp8_scaled.safetensors"
  local out="$3"
  if [ -f "$out" ] && [ -s "$out" ]; then
    echo "[hf] exists: $out"
    return 0
  fi
  echo "[hf] downloading: ${repo}/${remote_path}"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  if hf download "$repo" "$remote_path" --local-dir "$tmp_dir"; then
    mkdir -p "$(dirname "$out")"
    mv "${tmp_dir}/${remote_path}" "$out"
  else
    echo "[hf] WARNING: hf_download failed for ${repo}/${remote_path}"
  fi
  rm -rf "$tmp_dir"
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
  "${MODELS_DIR}/SEEDVR2"

# Cache custom nodes on persistent volume
REPO_CACHE="${PERSIST_DIR}/_repos"
mkdir -p "$REPO_CACHE"
UPDATE_NODES="${UPDATE_NODES:-0}"

# Clone/fetch ALL nodes in parallel (not batches!)
# SPEED NOTE: git clone (even --depth 1) still pays for full git protocol
# negotiation + delta resolution + a git-managed checkout of every file one by
# one. For vendored code you're not tracking history on, that's pure overhead.
# GitHub serves plain tarballs of any ref straight from codeload.github.com
# (already whitelisted in your network config) — one HTTP stream, no git
# protocol, extracted with tar. This is the single biggest speed win available
# here, especially for repos with lots of small files (ComfyUI_LayerStyle,
# ComfyUI-Manager). ComfyUI-Manager is the one exception: it's kept as a real
# git clone so its own in-app "Update" button still works (it shells out to
# git and expects a .git dir — a tarball drop would break that one feature).
echo "[nodes] Fetching custom nodes (fully parallel, tarball where possible)..."
GIT_CLONE_TIMEOUT="${GIT_CLONE_TIMEOUT:-180}"
NODE_CLONE_LOG_DIR="${PERSIST_DIR}/.clone-logs"
mkdir -p "$NODE_CLONE_LOG_DIR"

# pigz gives parallel (multi-core) gzip decompression instead of single-threaded
# tar -z, which matters once several tarballs extract at the same time.
if ! command -v pigz >/dev/null 2>&1; then
  apt-get install -y -qq pigz >/dev/null 2>&1 || true
fi

tarball_fetch() {
  local owner_repo="$1"   # e.g. "rgthree/rgthree-comfy"
  local ref="$2"          # "HEAD" for default branch, or a pinned commit sha
  local name="$3"
  local dest="${REPO_CACHE}/${name}"
  if [ -f "${dest}/.fetched_ok" ]; then
    echo "[nodes] exists: ${name}"
    return 0
  fi
  echo "[nodes] fetching ${name} (tarball)..."
  local url="https://codeload.github.com/${owner_repo}/tar.gz/${ref}"
  local log="${NODE_CLONE_LOG_DIR}/${name}.log"
  local tmp_tar
  tmp_tar="$(mktemp --suffix=.tar.gz)"
  local ok=0
  for attempt in 1 2; do
    if command -v aria2c >/dev/null 2>&1; then
      if timeout "${GIT_CLONE_TIMEOUT}" aria2c -x 8 -s 8 -k 1M \
           --max-tries=5 --retry-wait=2 --allow-overwrite=true \
           -d "$(dirname "$tmp_tar")" -o "$(basename "$tmp_tar")" \
           "$url" > "$log" 2>&1; then
        ok=1; break
      fi
    else
      if timeout "${GIT_CLONE_TIMEOUT}" curl -L --fail --retry 5 --retry-delay 2 \
           -o "$tmp_tar" "$url" > "$log" 2>&1; then
        ok=1; break
      fi
    fi
    echo "[nodes] ${name} attempt ${attempt} failed/timed out (see ${log}), retrying..."
  done
  if [ "$ok" != "1" ]; then
    echo "[nodes] WARNING: ${name} fetch failed after retries, see ${log}"
    rm -f "$tmp_tar"
    return 1
  fi
  rm -rf "$dest"
  mkdir -p "$dest"
  if command -v pigz >/dev/null 2>&1; then
    tar -I pigz -xf "$tmp_tar" -C "$dest" --strip-components=1 2>>"$log"
  else
    tar -xzf "$tmp_tar" -C "$dest" --strip-components=1 2>>"$log"
  fi
  rm -f "$tmp_tar"
  touch "${dest}/.fetched_ok"
  echo "[nodes] ${name} done"
}

(
  cd "$REPO_CACHE"

  # name : owner/repo : ref  (ref = "HEAD" for default branch, or a pinned sha)
  for repo in \
    "rgthree-comfy:rgthree/rgthree-comfy:HEAD" \
    "ComfyUI-Easy-Use:yolain/ComfyUI-Easy-Use:HEAD" \
    "ComfyUI_LayerStyle:chflame163/ComfyUI_LayerStyle:HEAD" \
    "ComfyUI-SeedVR2_VideoUpscaler:numz/ComfyUI-SeedVR2_VideoUpscaler:HEAD" \
    "ComfyUI-GridSplit:workordie/ComfyUI-GridSplit:b9941964ff879487aa3e9433b174548039748453" \
    "BatchnodeI9:rvspromotion-glitch/BatchnodeI9:HEAD" \
    "savezipi9:rvspromotion-glitch/savezipi9:HEAD" \
    "RES4LYF:ClownsharkBatwing/RES4LYF:HEAD"
  do
    name="${repo%%:*}"
    rest="${repo#*:}"
    owner_repo="${rest%%:*}"
    ref="${rest#*:}"
    ( tarball_fetch "$owner_repo" "$ref" "$name" ) &
  done

  # ComfyUI-Manager stays a real git clone so its own in-app updater keeps working
  (
    name="ComfyUI-Manager"
    url="https://github.com/Comfy-Org/ComfyUI-Manager.git"
    if [ ! -d "${name}/.git" ]; then
      echo "[nodes] cloning ${name}..."
      log="${NODE_CLONE_LOG_DIR}/${name}.log"
      ok=0
      for attempt in 1 2; do
        if GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true \
           GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30 \
           timeout "${GIT_CLONE_TIMEOUT}" git \
             -c http.extraHeader= -c credential.helper= -c core.askPass= \
             clone --depth 1 --single-branch --no-tags -q "$url" "$name" \
             > "$log" 2>&1; then
          ok=1; break
        fi
        echo "[nodes] ${name} attempt ${attempt} failed/timed out (see ${log}), retrying..."
        rm -rf "${name}"
      done
      if [ "$ok" = "1" ]; then
        echo "[nodes] ${name} done"
      else
        echo "[nodes] WARNING: ${name} failed after retries, see ${log}"
      fi
    elif [ "$UPDATE_NODES" = "1" ]; then
      echo "[nodes] updating ${name}..."
      git -C "$name" pull --rebase 2>/dev/null || true
    fi
  ) &

  wait
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

# Krea2 Turbo — using Comfy-Org's repackaged fp8 build, not the original
# krea/Krea-2-Turbo repo. Two reasons: (1) that original repo is standard
# git-LFS backed and throttles hard (was seen stuck at CN:7/~4MiB/s despite
# requesting 16 connections — a server-side cap); (2) it's also the *native*
# krea-ai layout, which may not load directly in UNETLoader/CLIPLoader/
# VAELoader — this fp8 build matches the text_encoders/vae files below.
# Pulled via hf_download (huggingface-cli + hf_transfer) rather than aria2c,
# since that's the only client that actually speaks Comfy-Org/Krea-2's Xet
# chunked protocol and gets its real speed benefit.
hf_download "Comfy-Org/Krea-2" "diffusion_models/krea2_turbo_fp8_scaled.safetensors" \
  "${MODELS_DIR}/diffusion_models/krea2_turbo_fp8_scaled.safetensors" &

# Krea2 required text encoder (Qwen3VL-4B, fp8) — goes in models/clip (not
# text_encoders) since that's where this workflow's CLIPLoader looks for it.
hf_download "Comfy-Org/Krea-2" "text_encoders/qwen3vl_4b_fp8_scaled.safetensors" \
  "${MODELS_DIR}/clip/qwen3vl_4b_fp8_scaled.safetensors" &

# VAE (qwen_image_vae, shared with Anima) — same repo, same client.
hf_download "Comfy-Org/Krea-2" "vae/qwen_image_vae.safetensors" \
  "${MODELS_DIR}/vae/qwen_image_vae.safetensors" &

# Krea2 Raw — Comfy-Org/Krea-2 ships this as a repackaged single-file model too
# (diffusion_models/krea2_raw_fp8_scaled.safetensors), same folder as Turbo.
# No multi-file diffusers snapshot needed — both Raw and Turbo load through
# ComfyUI's standard diffusion model loader.
hf_download "Comfy-Org/Krea-2" "diffusion_models/krea2_raw_fp8_scaled.safetensors" \
  "${MODELS_DIR}/diffusion_models/krea2_raw_fp8_scaled.safetensors" &

# Krea2 Turbo LoRA (rank 64) — for the RAW + LoRA @ 0.6 dual-sampler setup.
# Layers on top of krea2_raw_fp8_scaled.safetensors above, doesn't replace it.
hf_download "Comfy-Org/Krea-2" "loras/krea2_turbo_lora_rank_64_bf16.safetensors" \
  "${MODELS_DIR}/loras/krea2_turbo_lora_rank_64_bf16.safetensors" &

# Wan 2.1 VAE (FP32) — swap-in replacement for qwen_image_vae in the Krea 2
# pipeline; sharper decode, same latent format, no other graph changes needed.
# Public repo (not gated), still routed through hf_download per your call —
# it's the faster path for anything living on HF regardless of gating.
hf_download "Kijai/WanVideo_comfy" "Wan2_1_VAE_fp32.safetensors" \
  "${MODELS_DIR}/vae/Wan2_1_VAE_fp32.safetensors" &

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

# SeedVR2 DiT/VAE weights — pre-pulled here instead of letting the node
# auto-download on first run. Its built-in downloader has been observed
# stuck at ~2.8MB/s (1.5hr+ for the 15GB 7B model) since it doesn't use Xet;
# hf_download does. Folder must be models/SEEDVR2 (all caps) — that's the
# exact path the node reads from, confirmed from the runtime log.
# Swap seedvr2_ema_7b_sharp_fp16 below for seedvr2_ema_3b_fp16 (6.78GB) or
# seedvr2_ema_7b_fp8_e4m3fn (8.24GB) if you want a lighter/faster model instead.
hf_download "numz/SeedVR2_comfyUI" "ema_vae_fp16.safetensors" \
  "${MODELS_DIR}/SEEDVR2/ema_vae_fp16.safetensors" &

hf_download "numz/SeedVR2_comfyUI" "seedvr2_ema_7b_sharp_fp16.safetensors" \
  "${MODELS_DIR}/SEEDVR2/seedvr2_ema_7b_sharp_fp16.safetensors" &

wait
echo "[models] SeedVR2 weights ready!"

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
