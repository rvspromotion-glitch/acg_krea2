#!/usr/bin/env bash
# Fetch everything in models.txt into MODELS_DIR. Runs once, on first boot.
#
# On a pod /workspace is a persistent volume, so this is a first-boot cost only:
# every later start finds the files already there and skips in about a second.
#
# Two things keep the first boot short:
#
#   * Downloads run concurrently. Twelve files across three hosts, and no single
#     one of them saturates the link — HF is Xet-chunked and multi-connection,
#     Civitai is aria2 with 16 connections, and they overlap.
#   * Files land directly at their destination via a staging dir on the SAME
#     filesystem, so finishing a download is an instant rename. The old path
#     downloaded into the HF cache and then copied — for 50GB of weights that is
#     both a second copy of every byte on disk and several minutes of pure IO.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# In the image both live in /opt/krea2; in a git checkout the list is one level
# up from scripts/.
LIST="${MODELS_LIST:-}"
if [ -z "$LIST" ]; then
  [ -f "${HERE}/models.txt" ] && LIST="${HERE}/models.txt" || LIST="${HERE}/../models.txt"
fi
MODELS_DIR="${MODELS_DIR:-/workspace/models}"
PARALLEL="${MODEL_FETCH_PARALLEL:-4}"
PROGRESS_EVERY="${MODEL_FETCH_PROGRESS_EVERY:-20}"
MIN_BYTES="${MODEL_MIN_BYTES:-1048576}"
STAGE="${MODELS_DIR}/.staging"

log() { echo "[models] $*"; }

if [ ! -f "$LIST" ]; then
  echo "[models] FATAL: no model list at ${LIST}" >&2
  exit 1
fi

mkdir -p "$STAGE"

# A file is only real if it is big enough to be a model and does not start with
# '<' — an HTML login page saved as .safetensors is the classic gated-download
# failure, and it fails much later and far less legibly than it should.
is_model() {
  local p="$1"
  [ -f "$p" ] && [ "$(stat -c %s "$p" 2>/dev/null || echo 0)" -ge "$MIN_BYTES" ] \
    && [ "$(head -c 1 "$p")" != "<" ]
}

fetch_hf() {
  local repo="$1" remote="$2" dest="$3"
  # The Python API, not the CLI: `huggingface-cli download` is deprecated and
  # `hf download` is its replacement, whereas hf_hub_download has been stable
  # across both renames. local_dir= writes straight into the staging tree
  # instead of the shared cache, so there is never a second copy of a 12GB file.
  python3 - "$repo" "$remote" "$STAGE" <<'PY' || return 1
import os, sys
from huggingface_hub import hf_hub_download
repo, remote, stage = sys.argv[1:4]
hf_hub_download(repo_id=repo, filename=remote, local_dir=stage,
                token=os.environ.get("HF_TOKEN") or None)
PY
  mkdir -p "$(dirname "$dest")"
  mv -f "${STAGE}/${remote}" "$dest"
}

fetch_civit() {
  local url="$1" dest="$2"
  local token="${CIVITAI_TOKEN:-}"
  if [ -z "$token" ]; then
    echo "no CIVITAI_TOKEN set — this file is gated" >&2
    return 1
  fi
  mkdir -p "$(dirname "$dest")"

  # Civitai answers with a redirect to a signed CDN URL, and the CDN rejects a
  # request that still carries the Civitai Authorization header — which is why
  # handing aria2 the original URL plus the header fails and falls back to one
  # slow stream. So resolve the redirect first and give aria2 the signed URL
  # with no header at all.
  #
  # A *range* GET, not a HEAD: the signature is issued for the method that asked
  # for it, and a URL recovered from a HEAD chain serves a web page.
  local signed=""
  signed=$(curl -sS -L -o /dev/null -r 0-0 \
             -H "Authorization: Bearer ${token}" \
             -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
             -w '%{url_effective}' "$url" 2>/dev/null) || signed=""

  if [ -n "$signed" ] && [ "$signed" != "$url" ] && command -v aria2c >/dev/null 2>&1; then
    if aria2c -x 16 -s 16 -k 1M --split=16 --min-split-size=1M \
              --max-tries=5 --retry-wait=3 --connect-timeout=30 --timeout=60 \
              --allow-overwrite=true --file-allocation=none \
              --console-log-level=warn --summary-interval=0 \
              -d "$(dirname "$dest")" -o "$(basename "$dest")" "$signed"; then
      return 0
    fi
    echo "aria2 failed on the signed URL, falling back to curl" >&2
  fi

  # Single stream, but it needs nothing resolved in advance and curl drops the
  # auth header on the cross-host hop itself.
  curl -sSL --retry 8 --retry-delay 3 --retry-all-errors \
    -H "Authorization: Bearer ${token}" \
    -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
    -o "$dest" "$url"
}

# One model, start to finish. Runs in a background job; its output is captured
# and replayed by the caller so parallel downloads do not interleave.
fetch_one() {
  local kind="$1" dest
  if [ "$kind" = "hf" ]; then
    dest="$4"
    fetch_hf "$2" "$3" "$dest" || { echo "download failed" >&2; return 1; }
  else
    dest="$3"
    fetch_civit "$2" "$dest" || { echo "download failed" >&2; return 1; }
  fi
  if ! is_model "$dest"; then
    echo "not a model file (truncated, or an HTML error page):" >&2
    head -c 300 "$dest" 2>/dev/null | sed 's/^/  | /' >&2
    rm -f "$dest"
    return 1
  fi
  echo "ok $(basename "$dest") ($(du -h "$dest" | cut -f1))"
}

started=$(date +%s)
declare -a pids=() names=() logs=() wanted=()
present=0

# `|| [ -n "$raw" ]` so a final line with no trailing newline is still read.
while IFS= read -r raw || [ -n "$raw" ]; do
  # Strip a trailing inline comment BEFORE splitting. `read` assigns the whole
  # remainder of the line to its last variable, so "dest  # 4.4GB" would other-
  # wise become a filename with the size note inside it — which fails as a
  # confusing "downloaded but the node cannot find it", not as a parse error.
  line="${raw%%[[:space:]]#*}"
  # Deliberate word splitting on the cleaned line.
  # shellcheck disable=SC2086
  set -- $line
  kind="${1:-}"; a="${2:-}"; b="${3:-}"; c="${4:-}"
  case "$kind" in ""|\#*) continue ;; esac
  case "$kind" in
    hf)    rel="$c" ;;
    civit) rel="$b" ;;
    *)     echo "[models] FATAL: unknown kind '${kind}' in ${LIST}" >&2; exit 1 ;;
  esac

  dest="${MODELS_DIR}/${rel}"
  name="$(basename "$rel")"

  if is_model "$dest"; then
    present=$((present + 1))
    continue
  fi

  # Bound concurrency: wait for a slot before starting another.
  while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do sleep 1; done

  logfile="$(mktemp)"
  if [ "$kind" = "hf" ]; then
    fetch_one hf "$a" "$b" "$dest" >"$logfile" 2>&1 &
  else
    fetch_one civit "$a" "$dest" >"$logfile" 2>&1 &
  fi
  pids+=($!); names+=("$name"); logs+=("$logfile"); wanted+=("$dest")
  log "fetching ${name}…"
done < "$LIST"

[ "$present" -gt 0 ] && log "${present} already present, skipped"

if [ "${#pids[@]}" -eq 0 ]; then
  log "nothing to fetch"
  rm -rf "$STAGE"
  exit 0
fi

# Captured output means total silence for minutes otherwise, and the last line
# on screen would be whichever download *started* last — which reads as "stuck
# on a 100MB LoRA" when it is really the 12GB checkpoint still going. So: one
# compact line every PROGRESS_EVERY seconds with what is actually on disk.
# Sizes come off the filesystem, so it works the same for aria2 and for HF.
TICK_FLAG="$(mktemp)"
trap 'rm -f "$TICK_FLAG"' EXIT
(
  waited=0
  # Sleeps in one-second steps: `kill` on this subshell would not reach an
  # external `sleep` it is blocked in, and that orphan would hold the script's
  # stdout open for the rest of the interval.
  while [ -f "$TICK_FLAG" ]; do
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -lt "$PROGRESS_EVERY" ] && continue
    waited=0
    line=""
    for d in "${wanted[@]}"; do
      base="$(basename "$d")"
      short="${base%.safetensors}"
      # In flight it is under .staging (HF) or being written in place (aria2),
      # and done it is at $d. Take the largest match either way.
      sz="$( { [ -e "$d" ] && du -h "$d"; find "$STAGE" -name "${base}*" -exec du -h {} + ; } 2>/dev/null \
             | sort -h | tail -1 | cut -f1 )"
      line="${line}${short} ${sz:-…}  "
    done
    echo "[models] $(( $(date +%s) - started ))s  ${line}"
  done
) &
TICKER=$!

failed=0
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    sed 's/^/[models] /' "${logs[$i]}"
  else
    failed=$((failed + 1))
    echo "[models] FAILED: ${names[$i]}" >&2
    sed 's/^/[models]   /' "${logs[$i]}" >&2
  fi
  rm -f "${logs[$i]}"
done

rm -f "$TICK_FLAG"
wait "$TICKER" 2>/dev/null || true
trap - EXIT

elapsed=$(( $(date +%s) - started ))

if [ "$failed" -gt 0 ]; then
  echo "[models] FATAL: ${failed} of ${#pids[@]} download(s) failed after ${elapsed}s." >&2
  echo "[models]        A 401 above means CIVITAI_TOKEN is missing or wrong;" >&2
  echo "[models]        a 403 on a Comfy-Org/Krea-2 file means HF_TOKEN is not" >&2
  echo "[models]        an account that has accepted the Krea licence." >&2
  exit 1
fi

rm -rf "$STAGE"
log "ready — ${#pids[@]} fetched in ${elapsed}s, $(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1) on disk"
