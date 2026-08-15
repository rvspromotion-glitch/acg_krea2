# acg_krea2 — ComfyUI Krea2 pod

A ComfyUI image for a **RunPod pod** (not a serverless endpoint): the node set
and every Python dependency are baked in, the weights land on the pod's
persistent volume on first boot, and the entrypoint does nothing else.

## Running it on RunPod

1. **Template** → Docker image `<dockerhub-user>/comfyui-acg-krea2:<sha>`
   (pin the sha, not `:latest` — RunPod caches by tag).
2. **Volume** → mount at `/workspace`, **at least 100GB**. models.txt is ~50GB
   and a half-written checkpoint fails every render, so leave headroom.
3. **Ports** → `8188` (ComfyUI), `8888` (JupyterLab).
4. **Environment variables / secrets**

   | name | needed for |
   |---|---|
   | `HF_TOKEN` or secret `HF_TOKEN` | Krea-2 is gated — the token must belong to an account that accepted the licence on the model page |
   | `CIVITAI_TOKEN` or secret `CivitKey` | the four Civitai files in models.txt |
   | `CHAR_LORA_URL` | optional, pulls one character LoRA on boot |

First boot downloads ~50GB and takes as long as the link allows. Every boot
after that is a few seconds, because the volume already has the files.

### Other knobs

| variable | default | effect |
|---|---|---|
| `SKIP_MODELS` | `0` | `1` skips the model fetch entirely |
| `MODEL_FETCH_PARALLEL` | `4` | concurrent downloads |
| `START_JUPYTER` | `1` | `0` skips JupyterLab |
| `COMFY_ARGS` | `--disable-auto-launch --disable-metadata --preview-method auto` | replaces ComfyUI's flags |

`--disable-metadata` is not cosmetic: without it SaveImage writes the whole API
prompt into the PNG's tEXt chunks, which carries the Gemini API key from
`Ask_Gemini_Batch` in plaintext, plus the character LoRA name and the full system
prompt. These images get published.

## What is in the image

* ComfyUI, pinned (`COMFYUI_REF`, currently `v0.32.0`)
* the 16 custom node packages in `custom_nodes.txt`, plus ComfyUI-Manager
* every Python dependency, including each node package's `requirements.txt`
* the six graphs in `workflows/`, copied into the workflow browser on boot

Not in the image: the weights. `models.txt` is the list; `scripts/fetch_models.sh`
pulls it on first boot.

## Why it got faster

The old `start.sh` did nearly all of its work on **every** container start:

| was, per boot | now |
|---|---|
| 30s ping loop before anything else | gone — downloaders retry on their own |
| pip install numpy / mediapipe / sageattention / huggingface_hub | baked |
| `git clone` × 16 custom node repos | baked (tarballs, at build time) |
| `pip install -r requirements.txt` × 16 | baked, and as **one** pip run |
| `cp -a /opt/ComfyUI /workspace/ComfyUI` (whole tree) | gone — runs from `/opt`, four dirs symlinked to the volume |
| 3 sequential `wait` barriers between model batches | one pool, bounded by `MODEL_FETCH_PARALLEL` |
| HF download into the cache, then `cp` to destination | downloads into a staging dir on the same filesystem, so finishing is an instant rename — no second copy of 50GB |

And the build:

| was | now |
|---|---|
| pip installed torch + torchvision + torchaudio + xformers over a base that already has them | dropped — ~6GB downloaded and ~5GB of duplicated layer, for a stack the base already matches to its CUDA |
| pyqt5 (Qt), seaborn, insightface | dropped — nothing imports them, and insightface needs a compiler |
| 5 separate pip layers | 1 |
| `cache-from: type=gha` (10GB repo cap, thrashes) | registry cache on a `:buildcache` tag |
| build on `/` (~14GB free) | Docker data-root moved to `/mnt` (~70GB) |

## The opencv trap

`constraints.txt` asks for `opencv-contrib-python-headless`, but a pip
*constraint* only fixes the **version** of a package that gets installed — it
cannot stop a differently-named distribution from arriving as someone else's
dependency. Two of ours do exactly that:

```
ultralytics -> opencv-python
mediapipe   -> opencv-contrib-python
```

All three unpack into the same `site-packages/cv2`, so the winner is whichever
pip unpacked last. When `opencv-python` wins, `cv2.ximgproc.guidedFilter`
disappears and a handful of LayerStyle nodes break — quietly, at render time.
Note that `hasattr(cv2, "ximgproc")` still returns `True` in that state; the
directory survives, the bindings do not. That is why the check looks for
`guidedFilter` specifically.

`install_nodes.sh` therefore ends by removing every opencv variant and
reinstalling the contrib headless build alone, after all other pip activity. The
`<5` ceiling in `constraints.txt` matters too: opencv 5 declares `numpy>=2`, and
numpy 2 is the one thing this node set cannot have.

pip will warn `mediapipe requires opencv-contrib-python, which is not installed`.
That is metadata bookkeeping, not a real missing dependency — headless contrib
provides the same `cv2` module. Do not "fix" it by reinstalling the non-headless
build; that reintroduces the clobber.

## Editing the model list

`models.txt`, one per line:

```
hf     <repo>  <path-in-repo>  <dest under MODELS_DIR>
civit  <url>                   <dest under MODELS_DIR>
```

Destination filenames are what the graphs reference — renaming one here without
renaming it in `workflows/*.json` breaks the render, not the download.

## Relation to the serverless worker

This repo is the pod-mode sibling of `krea2_pipeline`: same node set, same
graphs, same weights. The RunPod handler, `src/`, and the serverless entrypoint
are deliberately absent — a pod serves the ComfyUI UI directly on 8188.
