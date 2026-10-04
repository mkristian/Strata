#!/usr/bin/env bash
#
# import_from_ramalama: link a ramalama store's blobs into Strata's models dir, so
# the ~70 GB download is skipped.
#
# Strata downloads its GGUF shards from Hugging Face into <data dir>/models/<tag>/.
# If you already have them in a ramalama store, this symlinks the store's blobs into
# that exact folder, so setup finds them on its normal path and skips the download.
# The shards are read through the symlinks (setup verifies each against its own GGUF
# tensor directory and marks it done).
#
# Usage:
#   import_from_ramalama.sh 'hf://ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0'
#   ./setup.sh --family qwen --model Q2_0
#
#   In the container, ~/.strata is the data dir:
#   docker run ... -v "$HOME/.strata":/data \
#     -v /usr/local/storage/ramalama/store:/usr/local/storage/ramalama/store:ro \
#     -e FAMILY=coder -e MODEL=IQ1_M strata-rocm
#
# Environment:
#   STRATA_RAMALAMA_STORE  the ramalama store root (default /usr/local/storage/ramalama/store)
#   STRATA_DATA_DIR        the Strata data dir (default ~/.strata); the model goes in <dir>/models/<tag>/
set -euo pipefail

STORE="${STRATA_RAMALAMA_STORE:-/usr/local/storage/ramalama/store}"
DATA="${STRATA_DATA_DIR:-$HOME/.strata}"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 'hf://<org>/<repo>:<model>'" >&2
  exit 2
fi
spec="$1"
[[ "$spec" == hf://* ]] || { echo "expected an hf:// reference, got: $spec" >&2; exit 2; }

# hf://<org>/<repo>:<model> -> repo = everything before the final ':', model = after it
rest="${spec#hf://}"
repo="${rest%:*}"
model="${rest##*:}"
[[ -n "$repo" && -n "$model" && "$repo" != "$rest" ]] || {
  echo "cannot split '$spec' into <repo>:<model>" >&2; exit 2; }

# Strata's models dir is <data>/models/<tag>/, where tag = <family>-<model> (qwen has no
# prefix). Derive the family from the repo name so the links land in the folder setup
# looks in.
case "$repo" in
  *Coder*)   fam_name="coder";   prefix="coder-" ;;
  *Swift*)   fam_name="swift";   prefix="swift-" ;;
  unsloth/*) fam_name="unsloth"; prefix="unsloth-" ;;
  *)         fam_name="qwen";    prefix="" ;;
esac
tag="${prefix}${model}"
DEST="$DATA/models/$tag"

refs="$STORE/huggingface/$repo/refs/$model.json"
blobs="$STORE/huggingface/$repo/blobs"
[[ -f "$refs" ]]  || { echo "no store manifest: $refs" >&2;  exit 1; }
[[ -d "$blobs" ]] || { echo "no blob directory: $blobs" >&2; exit 1; }

mkdir -p "$DEST"

# Read the manifest and link every .gguf file (the shards + the mmproj), skipping the
# chat template and any non-GGUF entry. Idempotent: re-running rebuilds the links.
python3 - "$refs" "$blobs" "$DEST" <<'PY'
import json, os, sys, pathlib

refs, blobs, dest = sys.argv[1], sys.argv[2], sys.argv[3]
manifest = json.loads(pathlib.Path(refs).read_text())
linked = 0
for f in manifest.get("files", []):
    base = os.path.basename(f.get("name", ""))
    if not base.endswith(".gguf"):
        continue
    blob = f.get("hash", "").replace(":", "-", 1)   # "sha256:<hex>" -> "sha256-<hex>" (the blob's name)
    src = os.path.abspath(os.path.join(blobs, blob))
    if not os.path.exists(src):
        print(f"  WARN missing blob for {base}: {src}", file=sys.stderr)
        continue
    dst = os.path.join(dest, base)
    if os.path.islink(dst) or os.path.exists(dst):
        os.remove(dst)
    os.symlink(src, dst)
    print(f"  {base} -> {src}")
    linked += 1
if linked == 0:
    sys.exit("no .gguf files found in the manifest")
PY

echo
echo "model files ready: $DEST"
ls -la "$DEST"
echo
echo "start it with:"
echo "  ./setup.sh --family $fam_name --model $model"
