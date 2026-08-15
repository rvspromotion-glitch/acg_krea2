# ComfyUI + Krea2 node set, for a RunPod POD (not serverless).
#
# The image carries ComfyUI, every custom node package and every Python
# dependency. It does NOT carry the weights — models.txt is ~50GB and neither
# fits a GitHub-hosted runner nor belongs in a layer you re-pull on every deploy.
# start.sh fetches them once onto the pod's persistent volume.
#
# Size discipline, because a hosted runner has ~14GB free on / and ~70GB on /mnt
# (the workflow moves Docker's data-root to /mnt, which is what makes this fit):
#
#   * The base image already ships torch 2.8.0 + cu128 + cuDNN, matched to each
#     other by RunPod. The previous Dockerfile then pip-installed torch,
#     torchvision, torchaudio and xformers over the top from the cu128 index —
#     that is ~6GB downloaded, ~5GB of duplicated layer, several minutes of
#     build, and a real chance of the ABI mismatch this base exists to avoid.
#     Do not add it back.
#   * pyqt5 (Qt, ~400MB, nothing imports it), seaborn and insightface (needs a
#     compiler and nothing in the node set asks for it) are gone for the same
#     reason.
#   * PIP_NO_CACHE_DIR everywhere, and __pycache__ swept in the layer that
#     creates it — a later RUN cannot shrink an earlier layer, it only writes a
#     whiteout on top and the bytes still ship.
FROM runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04

# Pin to a release, not master: a moving ComfyUI under a fixed dependency set is
# two things in motion, and the collision surfaces as a traceback pointing at
# neither. It has to be recent though — these graphs load a krea2 text encoder,
# and CLIPLoader only learned that type well after v0.9.2.
ARG COMFYUI_REF=v0.32.0
ARG INSTALL_MANAGER=1

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_PREFER_BINARY=1 \
    PIP_ROOT_USER_ACTION=ignore \
    COMFYUI_PATH=/opt/ComfyUI \
    MODELS_DIR=/workspace/models \
    # These graphs run several samplers back to back at a fixed resolution,
    # which fragments the caching allocator enough to OOM a 24GB card partway
    # through a carousel even though no single step is close to the limit.
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    # hf_xet is the current accelerated transfer backend and a recent
    # huggingface_hub picks it up on its own; HIGH_PERFORMANCE raises its
    # concurrency. hf_transfer is kept enabled for repos not yet on Xet.
    HF_XET_HIGH_PERFORMANCE=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1

# aria2 is what makes the Civitai side of the first boot minutes rather than
# tens of minutes; pigz is parallel gunzip for the node tarballs. ffmpeg, libgl
# and libglib are the node set's.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl aria2 pigz ffmpeg libgl1 libglib2.0-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Python dependencies ─────────────────────────────────────────────────────
# One layer, because each `pip install` re-reads the environment and re-runs the
# resolver, and five of them was minutes of nothing.
COPY constraints.txt /opt/krea2/constraints.txt
ENV PIP_CONSTRAINT=/opt/krea2/constraints.txt
# The opencv variants all install into the same site-packages/cv2 directory, so
# having two of them present is not "both work" — it is whichever unpacked last,
# with the other's files half overwritten. The base image ships one, mediapipe
# pulls opencv-contrib-python and ultralytics pulls opencv-python, so this layer
# ends with three of them and cv2.ximgproc.guidedFilter gone. Hence the sweep at
# both ends: drop every variant first, and put the contrib headless build back
# last, in this same layer so the ones we do not want never ship.
# install_nodes.sh repeats the tail end after the node requirements have had
# their say; the full explanation lives there.
RUN pip uninstall -y opencv-python opencv-python-headless \
                     opencv-contrib-python opencv-contrib-python-headless >/dev/null 2>&1 || true; \
    set -e; \
    pip install -r /opt/krea2/constraints.txt; \
    pip install \
        "huggingface_hub[hf_xet]>=0.34" hf_transfer \
        jupyterlab \
        ultralytics segment-anything sentencepiece onnxruntime-gpu \
        google-generativeai \
        accelerate diffusers einops ftfy kornia timm spandrel \
        scikit-image scipy PyWavelets piexif dill lpips soundfile \
        matplotlib omegaconf hydra-core iopath; \
    pip uninstall -y opencv-python opencv-python-headless \
                     opencv-contrib-python opencv-contrib-python-headless >/dev/null 2>&1 || true; \
    pip install --force-reinstall opencv-contrib-python-headless; \
    find /usr/local/lib/python3.11 -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

# ── ComfyUI ─────────────────────────────────────────────────────────────────
RUN git clone --depth 1 --single-branch --no-tags --branch ${COMFYUI_REF} \
        https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI \
 && rm -rf /opt/ComfyUI/.git \
 && pip install -r /opt/ComfyUI/requirements.txt

# ── Custom nodes ────────────────────────────────────────────────────────────
# The single biggest change in this repo: these used to be cloned and pip
# installed on every container start.
COPY custom_nodes.txt /opt/krea2/custom_nodes.txt
COPY scripts/install_nodes.sh /opt/krea2/install_nodes.sh
RUN chmod +x /opt/krea2/install_nodes.sh \
 && INSTALL_MANAGER=${INSTALL_MANAGER} \
    /opt/krea2/install_nodes.sh /opt/krea2/custom_nodes.txt /opt/ComfyUI/custom_nodes \
 && find /usr/local/lib/python3.11 -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

# ── Build-time sanity check ─────────────────────────────────────────────────
# Five seconds, and it catches the two failures that otherwise only show up on a
# GPU mid-render: a node package having quietly replaced torch with a CPU wheel
# (every render then runs a hundred times slower, with no error), and the plain
# opencv build having overwritten the contrib one (LayerStyle loses ximgproc).
# It cannot check the GPU — there isn't one on a build runner — so it checks the
# build metadata, which is where the damage would show.
COPY scripts/verify_build.py /opt/krea2/verify_build.py
RUN python3 /opt/krea2/verify_build.py

# ── Everything that changes often, last, so a tweak here rebuilds nothing above
COPY workflows/ /opt/workflows/
COPY models.txt /opt/krea2/models.txt
COPY scripts/fetch_models.sh /opt/krea2/fetch_models.sh
COPY start.sh /start.sh
RUN chmod +x /start.sh /opt/krea2/fetch_models.sh

# 8188 ComfyUI, 8888 JupyterLab.
EXPOSE 8188 8888
CMD ["/start.sh"]
