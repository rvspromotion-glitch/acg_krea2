#!/usr/bin/env bash
# Pod entrypoint. Everything that can be decided at build time already has been,
# so all this does is wire the persistent volume in, make sure the weights are
# there, and start ComfyUI.
#
# What used to happen here and no longer does — this is the cold start you were
# waiting on:
#
#   * a 30s ping loop against 8.8.8.8 before anything else
#   * pip installing numpy/mediapipe/sageattention/huggingface_hub on every boot
#   * cloning sixteen custom node repos from GitHub on every boot
#   * `pip install -r requirements.txt` for each of those sixteen
#   * `cp -a /opt/ComfyUI /workspace/ComfyUI` — copying the whole tree, per boot
#   * three sequential `wait` barriers between the model download batches
#
# All of it is baked into the image now, and ComfyUI runs from /opt where it was
# built. First boot is one parallel model download; every boot after that is a
# few seconds.
set -euo pipefail
t0=$(date +%s)

COMFY_DIR="${COMFYUI_PATH:-/opt/ComfyUI}"
WORKSPACE="${WORKSPACE_DIR:-/workspace}"
export MODELS_DIR="${MODELS_DIR:-${WORKSPACE}/models}"

if [ ! -f "${COMFY_DIR}/main.py" ]; then
  echo "[fatal] ComfyUI not found at ${COMFY_DIR}. The image is broken —"
  echo "        rebuild it; there is nothing to configure at runtime."
  exit 1
fi

# ── Persistent state ────────────────────────────────────────────────────────
# On a RunPod pod the volume is mounted at /workspace and it is the only thing
# that survives a stop/start. ComfyUI itself stays where it was built (/opt), so
# nothing is copied on boot; only the four directories whose contents you would
# hate to lose get pointed at the volume.
for pair in "models:${MODELS_DIR}" \
            "output:${WORKSPACE}/output" \
            "input:${WORKSPACE}/input" \
            "user:${WORKSPACE}/comfy-user"; do
  name="${pair%%:*}"; target="${pair#*:}"
  link="${COMFY_DIR:?}/${name}"
  mkdir -p "$target"
  # Guard against COMFYUI_PATH/MODELS_DIR being set so that the link and its
  # target are the same place — that would be `rm -rf` on the models.
  [ "$(readlink -f "$link" 2>/dev/null)" = "$(readlink -f "$target")" ] && continue
  if [ -d "$link" ] && [ ! -L "$link" ]; then
    # Baked-in content (ComfyUI's empty model subdirs, its default user config)
    # moves to the volume rather than being thrown away. -n never overwrites.
    cp -rn "$link"/. "$target"/ 2>/dev/null || true
  fi
  rm -rf "$link"
  ln -sfn "$target" "$link"
done

mkdir -p "${MODELS_DIR}"/{checkpoints,clip,clip_vision,diffusion_models,loras,vae,controlnet,upscale_models,SEEDVR2}

# The graphs ship in the image; drop them into the persistent user dir so they
# show up in the workflow browser. -n, so your edits are never overwritten.
if [ -d /opt/workflows ]; then
  mkdir -p "${WORKSPACE}/comfy-user/default/workflows"
  cp -rn /opt/workflows/. "${WORKSPACE}/comfy-user/default/workflows/" 2>/dev/null || true
fi

# Anything a node auto-downloads (DepthAnythingV2, BiRefNet, …) lands on the
# volume too, so it is fetched once ever rather than once per pod start.
export HF_HOME="${HF_HOME:-${WORKSPACE}/.cache/huggingface}"
mkdir -p "$HF_HOME"

# ── Credentials ─────────────────────────────────────────────────────────────
# RunPod exposes secrets as RUNPOD_SECRET_<name>. Krea-2 is under Krea's custom
# community licence, which HF treats as gated: the token has to belong to an
# account that has clicked "agree" on the model page.
: "${HF_TOKEN:=${RUNPOD_SECRET_HF_TOKEN:-}}"
: "${CIVITAI_TOKEN:=${RUNPOD_SECRET_CivitKey:-}}"
export HF_TOKEN CIVITAI_TOKEN

# ── Weights ─────────────────────────────────────────────────────────────────
# Before ComfyUI, not alongside it: ComfyUI caches its model folder listing at
# startup, and a checkpoint that appears afterwards is a validation error on the
# first render rather than a load. Skip-if-present, so this is a first-boot cost.
if [ "${SKIP_MODELS:-0}" != "1" ]; then
  /opt/krea2/fetch_models.sh
fi

# Optional per-character LoRA, pulled from a URL set on the pod.
if [ -n "${CHAR_LORA_URL:-}" ]; then
  name="$(basename "${CHAR_LORA_URL%%\?*}")"
  dest="${MODELS_DIR}/loras/${name:-character_lora.safetensors}"
  if [ ! -s "$dest" ]; then
    echo "[models] fetching character LoRA ${name}"
    aria2c -x 8 -s 8 -k 1M --allow-overwrite=true --file-allocation=none \
      --console-log-level=warn -d "$(dirname "$dest")" -o "$(basename "$dest")" \
      "$CHAR_LORA_URL" || echo "[models] WARNING: character LoRA fetch failed"
  fi
fi

# ── Services ────────────────────────────────────────────────────────────────
if [ "${START_JUPYTER:-1}" = "1" ]; then
  echo "[jupyter] http://<pod>:8888"
  jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
    --ServerApp.token='' --ServerApp.password='' --ServerApp.allow_origin='*' \
    --ServerApp.root_dir="$WORKSPACE" \
    >"${WORKSPACE}/jupyter.log" 2>&1 &
fi

echo "[startup] ready in $(( $(date +%s) - t0 ))s — launching ComfyUI on :8188"

cd "$COMFY_DIR"
# --disable-metadata is not cosmetic: SaveImage otherwise writes the whole API
# prompt into the PNG's tEXt chunks, which carries the Ask_Gemini_Batch node and
# therefore the Gemini API key in plaintext, plus the character LoRA filename and
# the full system prompt. These images get published. Drop it from COMFY_ARGS
# only for local debugging.
exec python3 main.py --listen 0.0.0.0 --port 8188 \
  ${COMFY_ARGS:---disable-auto-launch --disable-metadata --preview-method auto}
