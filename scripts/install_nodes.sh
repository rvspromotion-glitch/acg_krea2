#!/usr/bin/env bash
# Install the custom node packages listed in custom_nodes.txt. BUILD TIME ONLY —
# nothing here runs on a pod start.
#
# Three things make this fast:
#
#   1. Tarballs from codeload, not `git clone`. A clone pays for protocol
#      negotiation, delta resolution and a git-managed checkout of every file
#      one at a time; codeload is a single compressed HTTP stream. On repos with
#      thousands of small files (LayerStyle, Impact-Pack) that is several times
#      quicker, and it leaves no .git directory in the image.
#   2. All packages fetched concurrently (xargs -P).
#   3. ONE pip install for every package's requirements combined, instead of one
#      pip run per package. Each pip invocation re-reads the environment and
#      re-runs the resolver; sixteen of them is minutes of pure overhead.
set -euo pipefail

LIST="${1:?custom_nodes.txt required}"
CUSTOM_NODES="${2:?custom_nodes dir required}"
INSTALL_MANAGER="${INSTALL_MANAGER:-1}"
JOBS="${NODE_FETCH_JOBS:-8}"

mkdir -p "$CUSTOM_NODES"

fetch_one() {
  local name="$1" repo="$2" ref="${3:-HEAD}"
  local dest="${CUSTOM_NODES}/${name}"
  local tmp
  tmp="$(mktemp --suffix=.tar.gz)"
  if ! curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
        -o "$tmp" "https://codeload.github.com/${repo}/tar.gz/${ref}"; then
    rm -f "$tmp"
    # Fallback for networks that block codeload but allow git over HTTPS.
    # Slower, hence not the default, but a build that works beats one that is
    # marginally quicker and does not.
    echo "[nodes] ${name}: codeload unavailable, falling back to git clone" >&2
    rm -rf "$dest"
    if [ "$ref" = "HEAD" ]; then
      git clone --depth 1 --single-branch --no-tags -q \
        "https://github.com/${repo}.git" "$dest" || {
          echo "[nodes] FATAL: could not fetch ${repo}@${ref}" >&2; return 1; }
    else
      git clone --no-checkout --filter=blob:none -q \
        "https://github.com/${repo}.git" "$dest" \
        && git -C "$dest" checkout -q "$ref" || {
          echo "[nodes] FATAL: could not fetch ${repo}@${ref}" >&2; return 1; }
    fi
    rm -rf "${dest}/.git"
    echo "[nodes] ${name} <- ${repo}@${ref} (git)"
    return 0
  fi
  rm -rf "$dest"
  mkdir -p "$dest"
  # pigz where present: parallel gunzip, and several of these land at once.
  if command -v pigz >/dev/null 2>&1; then
    tar -I pigz -xf "$tmp" -C "$dest" --strip-components=1
  else
    tar -xzf "$tmp" -C "$dest" --strip-components=1
  fi
  rm -f "$tmp"
  echo "[nodes] ${name} <- ${repo}@${ref}"
}
export -f fetch_one
export CUSTOM_NODES

echo "[nodes] fetching packages (${JOBS} at a time)…"
# -L 1 hands each line's words to bash as $1 $2 $3. A failure anywhere makes
# xargs exit non-zero, which set -e turns into a failed build — which is what
# you want: a missing node package is a broken image, found now rather than on
# the first render.
grep -vE '^[[:space:]]*(#|$)' "$LIST" | xargs -P "$JOBS" -L 1 bash -c 'fetch_one "$@"' _

# ComfyUI-Manager stays a real (shallow) git clone: its in-app updater shells
# out to git and needs a .git dir. On a pod the Manager UI is worth having.
if [ "$INSTALL_MANAGER" = "1" ]; then
  echo "[nodes] cloning ComfyUI-Manager"
  git clone --depth 1 --single-branch --no-tags -q \
    https://github.com/Comfy-Org/ComfyUI-Manager.git \
    "${CUSTOM_NODES}/ComfyUI-Manager"
fi

# BatchnodeI9 and savezipi9 are first-party and ship their node packages one
# level down, so ComfyUI would not see them where the others sit.
for parent in BatchnodeI9 savezipi9; do
  dir="${CUSTOM_NODES}/${parent}"
  [ -d "$dir" ] || continue
  [ -f "${dir}/__init__.py" ] && continue
  for sub in "$dir"/*/; do
    [ -f "${sub}__init__.py" ] || continue
    echo "[nodes] hoisting $(basename "$sub") out of ${parent}"
    mv "$sub" "${CUSTOM_NODES}/$(basename "$sub")"
  done
  # rm -rf, not rmdir: a leftover README keeps the directory alive, and ComfyUI
  # then tries to import a package with no __init__.py and logs a traceback on
  # every boot.
  rm -rf "$dir"
done

# Never let a node package pull its own torch: it would silently replace the
# cu128 build from the base image with a CPU wheel, and every render would then
# run on the CPU at a hundredth of the speed. opencv likewise — several packages
# ask for plain opencv-python, which overwrites the contrib build and takes
# cv2.ximgproc with it.
BLOCKED='^[[:space:]]*(torch|torchvision|torchaudio|torchsde|numpy|transformers|tokenizers|protobuf|opencv-python|opencv-python-headless|opencv-contrib-python|onnxruntime)([[:space:]]*[<=>!~].*)?$'

combined="$(mktemp)"
for req in "${CUSTOM_NODES}"/*/requirements.txt; do
  [ -f "$req" ] || continue
  grep -viE "$BLOCKED" "$req" >> "$combined" || true
done
# Strip CRs (several of these packages are authored on Windows and a trailing
# \r makes pip look for a package whose name ends in a carriage return), blank
# lines, comments, and -r/-e/--index-url style directives that only make sense
# relative to the file they came from.
sed -i -E 's/\r$//; /^[[:space:]]*(#|$)/d; /^[[:space:]]*-/d' "$combined"
sort -u -o "$combined" "$combined"

echo "[nodes] installing $(wc -l < "$combined") requirement lines in one pass"
if ! pip install --no-cache-dir --prefer-binary -r "$combined"; then
  # One package pinning something incompatible must not cost the other fifteen
  # their dependencies, so fall back to installing them one line at a time.
  echo "[nodes] combined install failed, retrying line by line"
  while read -r line; do
    [ -n "$line" ] || continue
    pip install --no-cache-dir --prefer-binary "$line" \
      || echo "[nodes] WARNING: could not install '${line}'"
  done < "$combined"
fi
rm -f "$combined"

# Trim what will never be read at runtime. Worth doing in this layer rather than
# a later one — a later RUN cannot shrink an earlier layer, it only adds a
# whiteout on top and the bytes still ship.
find "$CUSTOM_NODES" -maxdepth 2 -type d -name '.github' -prune -exec rm -rf {} + 2>/dev/null || true
find "$CUSTOM_NODES" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

echo "[nodes] done — $(find "$CUSTOM_NODES" -maxdepth 1 -mindepth 1 -type d | wc -l) packages, $(du -sh "$CUSTOM_NODES" | cut -f1)"
