# =============================================================================
# ACG ComfyUI runtime — KREA2 Carousel + SeedVR2 Upscaler workflow
#
# Design goals:
#   1. Modern CUDA (12.8) for driver/GPU stability on newer cards.
#   2. Multi-stage build so build tools (gcc, git, headers) never ship in the
#      final image — only the installed venv + node code does.
#   3. Zero model weights baked in. SeedVR2/Krea2/VAE/LoRA files are pulled by
#      start.sh at container boot into a volume-mountable models/ dir, so the
#      image itself stays in the low single-digit GBs and GitHub Actions'
#      runner disk (~14GB free by default) doesn't choke on the build.
#
# CUDA/torch note: SeedVR2's README pins torch==2.6.0/cu126, but nothing in
# its code is actually version-locked to that — it runs fine on newer
# combos. Using torch 2.7.1+cu128 here for better support on newer GPUs.
# If SeedVR2 ever breaks on this combo, drop back to the commented cu126
# line below — that's the officially-tested pairing.
# =============================================================================

ARG CUDA_TAG=12.8.1-cudnn-runtime-ubuntu22.04
ARG CUDA_DEVEL_TAG=12.8.1-cudnn-devel-ubuntu22.04
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu128
ARG TORCH_VERSION=2.7.1
ARG TORCHVISION_VERSION=0.22.1
ARG TORCHAUDIO_VERSION=2.7.1
# Fallback known-good combo for SeedVR2, if needed:
#   TORCH_INDEX=https://download.pytorch.org/whl/cu126
#   TORCH_VERSION=2.6.0 / TORCHVISION_VERSION=0.21.0 / TORCHAUDIO_VERSION=2.6.0
#   CUDA_TAG=12.6.3-cudnn-runtime-ubuntu22.04 / CUDA_DEVEL_TAG=12.6.3-cudnn-devel-ubuntu22.04

# =============================================================================
# Stage 1: builder — has git/compilers, builds a venv we can copy out whole
# =============================================================================
FROM nvidia/cuda:${CUDA_DEVEL_TAG} AS builder
ARG TORCH_INDEX
ARG TORCH_VERSION
ARG TORCHVISION_VERSION
ARG TORCHAUDIO_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    COMFYUI_PATH=/workspace/ComfyUI

RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common curl git ca-certificates build-essential \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-dev python3.12-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3.12 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --upgrade pip

WORKDIR /workspace
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git $COMFYUI_PATH

# Torch first (biggest layer, changes least often -> best cache hit rate)
RUN pip install torch==${TORCH_VERSION} torchvision==${TORCHVISION_VERSION} torchaudio==${TORCHAUDIO_VERSION} \
        --index-url ${TORCH_INDEX}

RUN pip install -r $COMFYUI_PATH/requirements.txt

WORKDIR $COMFYUI_PATH/custom_nodes

RUN git clone --depth 1 https://github.com/Comfy-Org/ComfyUI-Manager.git comfyui-manager && \
    pip install -r comfyui-manager/requirements.txt

RUN git clone --depth 1 https://github.com/rgthree/rgthree-comfy.git rgthree-comfy && \
    if [ -f rgthree-comfy/requirements.txt ]; then pip install -r rgthree-comfy/requirements.txt; fi

RUN git clone --depth 1 https://github.com/yolain/ComfyUI-Easy-Use.git comfyui-easy-use && \
    pip install -r comfyui-easy-use/requirements.txt

RUN git clone --depth 1 https://github.com/chflame163/ComfyUI_LayerStyle.git comfyui_layerstyle && \
    pip install -r comfyui_layerstyle/requirements.txt

RUN git clone --depth 1 https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git seedvr2_videoupscaler && \
    pip install -r seedvr2_videoupscaler/requirements.txt

RUN git clone https://github.com/workordie/ComfyUI-GridSplit.git comfyui-gridsplit && \
    cd comfyui-gridsplit && \
    git checkout b9941964ff879487aa3e9433b174548039748453 && \
    if [ -f requirements.txt ]; then pip install -r requirements.txt; fi

# --- Ask_Gemini_Batch / any other private custom node ------------------------
# This one (no cnr_id/aux_id in the workflow JSON, not in the ComfyUI
# registry) is NOT baked in at build time. It's pulled at container boot by
# start.sh via the CUSTOM_NODE_REPO_URL env var instead — set that when you
# run the container and it clones + pip installs automatically. Nothing to
# do here at build time.

# Strip .git dirs and caches out of the node folders before copying to final stage
RUN find /workspace -type d -name ".git" -prune -exec rm -rf {} + && \
    find /opt/venv -type d -name "__pycache__" -prune -exec rm -rf {} + && \
    find /opt/venv -type d -name "tests" -prune -exec rm -rf {} + && \
    rm -rf /opt/venv/lib/python3.12/site-packages/**/*.dist-info/RECORD \
    /root/.cache

# =============================================================================
# Stage 2: runtime — slim, no compilers, no git history, no build cache
# =============================================================================
FROM nvidia/cuda:${CUDA_TAG} AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    COMFYUI_PATH=/workspace/ComfyUI \
    PATH="/opt/venv/bin:$PATH"

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.12 libgl1 libglib2.0-0 ffmpeg curl ca-certificates git-lfs wget \
    && rm -rf /var/lib/apt/lists/*
# note: git-lfs/wget/curl kept — they're needed at *runtime* by start.sh to
# pull model weights on first boot, not by the build itself.

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /workspace/ComfyUI $COMFYUI_PATH

WORKDIR $COMFYUI_PATH

COPY KREA2_Carousel___upscaler_ACG.json /workspace/workflows/KREA2_Carousel___upscaler_ACG.json
COPY start.sh /workspace/start.sh
RUN chmod +x /workspace/start.sh

EXPOSE 8188
ENTRYPOINT ["/workspace/start.sh"]
