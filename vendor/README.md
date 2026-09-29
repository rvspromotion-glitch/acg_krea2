# Vendored third-party files

## custom_nodes/viggle_turbo.py

Provides `ViggleTurboSigmas` and `ViggleTurboLora`, the two nodes the
Qwen-Image-2.1 viggle-turbo LoRA needs.

    source  https://huggingface.co/Viggle/Qwen-Image-2.1-viggle-turbo/resolve/main/comfyui/viggle_turbo.py
    sha256  017911bb7d9c855c6ea6854adeeeea1aed576ca1c9cb487376419f5bae14e93d
    bytes   5469
    fetched 2026-09-29, byte-identical to upstream (verify with the sha above)

**Why vendored rather than installed like every other node.** It lives on
Hugging Face, not GitHub, so `install_nodes.sh` cannot reach it — that script
speaks codeload tarballs and git. Pinning a copy is also the better option on
its merits here: upstream's own README calls the ComfyUI port "mostly
vibe-coded with an AI coding assistant" and warns of rough edges, and the file
sits on a mutable `main`, so a build that curled it would silently change
under us.

**Why the LoRA needs it at all.** `ViggleTurboLora` applies the LoRA as a
runtime side branch (y = Wx + BAx) instead of merging it into the weights.
Upstream measured what merging costs: on bf16 round-to-nearest keeps only ~70%
of the update, and **on int8 the stochastic requantisation adds noise about 4x
the size of the update**. We run the int8_convrot diffusion model, so merging
through `LoraLoaderModelOnly` is the bad path. It is also a diffusers-format
LoRA keyed `transformer.*.lora_A.weight` with its rank and alpha in
`lora_adapter_metadata`, which this node reads and core loaders do not.

`ViggleTurboSigmas` computes the 6-step schedule with the resolution-dependent
shift (mu from the token count of the incoming latent). Hardcoded sigmas would
be wrong at any resolution but the one they were taken from.

Verified against ComfyUI v0.37.0: `comfy.patcher_extension.WrappersMP.DIFFUSION_MODEL`,
`ModelPatcher.add_wrapper_with_key`, `comfy.utils.load_torch_file(return_metadata=)`
and `folder_paths.get_full_path_or_raise` all exist there.

### Updating

    curl -sSL -o vendor/custom_nodes/viggle_turbo.py \
      https://huggingface.co/Viggle/Qwen-Image-2.1-viggle-turbo/resolve/main/comfyui/viggle_turbo.py

then re-record the sha256 above and rebuild. Read the diff first.
