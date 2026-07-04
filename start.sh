#!/usr/bin/env bash
set -euo pipefail

COMFYUI_PATH="${COMFYUI_PATH:-/workspace/ComfyUI}"
LISTEN_HOST="${LISTEN_HOST:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-8188}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

# Where model weights live. Point this at a mounted persistent volume
# (RunPod network volume, VPS bind mount, etc.) so weights survive container
# restarts and you're not re-downloading 15GB+ every boot.
MODELS_DIR="${MODELS_DIR:-/workspace/models}"

echo "=== ACG ComfyUI container starting ==="
echo "Python: $(python --version)"
echo "Torch:  $(python -c 'import torch; print(torch.__version__)')"
echo "CUDA available: $(python -c 'import torch; print(torch.cuda.is_available())')"
if python -c "import torch; exit(0 if torch.cuda.is_available() else 1)"; then
    python -c "import torch; print('GPU:', torch.cuda.get_device_name(0))"
else
    echo "WARNING: no CUDA device visible to torch. Check --gpus flag / runtime config."
fi

mkdir -p "${MODELS_DIR}"

# If a persistent volume is mounted, point ComfyUI's models/ dir at it instead
# of the ephemeral container filesystem.
if [ ! -L "${COMFYUI_PATH}/models" ]; then
    rm -rf "${COMFYUI_PATH}/models"
    ln -s "${MODELS_DIR}" "${COMFYUI_PATH}/models"
fi

mkdir -p "${MODELS_DIR}/diffusion_models" "${MODELS_DIR}/vae" "${MODELS_DIR}/clip" \
         "${MODELS_DIR}/loras" "${MODELS_DIR}/SeedVR2"

# -----------------------------------------------------------------------------
# SeedVR2 DiT/VAE weights: the node itself auto-downloads these from
# HuggingFace on first execution (numz/ComfyUI-SeedVR2_VideoUpscaler handles
# this internally, writing into models/SeedVR2/). Nothing to script here —
# just make sure MODELS_DIR is persistent so it only happens once.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Krea2 UNET / VAE / CLIP / LoRAs: these are your own private model files, not
# public downloads, so they aren't scripted here. Point WEIGHTS_SOURCE_URL at
# wherever you host them (private HF repo, Dropbox, S3, your VPS) and fill in
# the fetch commands below, e.g.:
#
#   if [ ! -f "${MODELS_DIR}/diffusion_models/krea2_turbo.safetensors" ]; then
#       curl -L "${WEIGHTS_SOURCE_URL}/krea2_turbo.safetensors" \
#           -o "${MODELS_DIR}/diffusion_models/krea2_turbo.safetensors"
#   fi
#
# Left as a no-op so the container still boots without them for a code-only
# deploy/test.
# -----------------------------------------------------------------------------
if [ -n "${WEIGHTS_SOURCE_URL:-}" ]; then
    echo "WEIGHTS_SOURCE_URL set — add your fetch commands in start.sh to pull Krea2 weights."
fi

if [ ! -f "${MODELS_DIR}/diffusion_models/krea2_turbo.safetensors" ]; then
    curl -L "${WEIGHTS_SOURCE_URL}/krea2_turbo.safetensors" \
        -o "${MODELS_DIR}/diffusion_models/krea2_turbo.safetensors"
fi

# -----------------------------------------------------------------------------
# Custom node repo, pulled at runtime instead of baked into the image.
# Set CUSTOM_NODE_REPO_URL when running the container, e.g.:
#   docker run -e CUSTOM_NODE_REPO_URL=https://github.com/you/ask-gemini-batch ...
# Optional: CUSTOM_NODE_REPO_BRANCH to pin a branch/tag (defaults to the
# repo's default branch).
#
# Wrapped so a bad URL, network hiccup, or broken requirements.txt logs a
# warning and lets ComfyUI boot anyway instead of crashing the container —
# you'd rather have ComfyUI up without the extra node than not up at all.
# -----------------------------------------------------------------------------
if [ -n "${CUSTOM_NODE_REPO_URL:-}" ]; then
    set +e
    NODE_NAME="$(basename "${CUSTOM_NODE_REPO_URL}" .git)"
    NODE_DIR="${COMFYUI_PATH}/custom_nodes/${NODE_NAME}"

    if [ -d "${NODE_DIR}/.git" ]; then
        echo "Updating custom node: ${NODE_NAME}"
        git -C "${NODE_DIR}" fetch --depth 1 origin "${CUSTOM_NODE_REPO_BRANCH:-HEAD}" 2>&1
        git -C "${NODE_DIR}" reset --hard FETCH_HEAD 2>&1
    else
        echo "Cloning custom node: ${NODE_NAME} from ${CUSTOM_NODE_REPO_URL}"
        if [ -n "${CUSTOM_NODE_REPO_BRANCH:-}" ]; then
            git clone --depth 1 --branch "${CUSTOM_NODE_REPO_BRANCH}" "${CUSTOM_NODE_REPO_URL}" "${NODE_DIR}" 2>&1
        else
            git clone --depth 1 "${CUSTOM_NODE_REPO_URL}" "${NODE_DIR}" 2>&1
        fi
    fi

    if [ -d "${NODE_DIR}" ]; then
        if [ -f "${NODE_DIR}/requirements.txt" ]; then
            echo "Installing requirements for ${NODE_NAME}"
            pip install --no-cache-dir -r "${NODE_DIR}/requirements.txt" 2>&1
            if [ $? -ne 0 ]; then
                echo "WARNING: pip install failed for ${NODE_NAME} — node may not load, continuing boot anyway."
            fi
        fi
    else
        echo "WARNING: failed to clone ${CUSTOM_NODE_REPO_URL} — continuing boot without it."
    fi
    set -e
fi

cd "${COMFYUI_PATH}"

exec python main.py \
    --listen "${LISTEN_HOST}" \
    --port "${LISTEN_PORT}" \
    ${EXTRA_ARGS}
