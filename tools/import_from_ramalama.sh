#!/usr/bin/env bash
#
# import_from_ramalama: build a Strata --gguf-dir from a ramalama store by symlinking its blobs.
#
# Strata downloads its GGUF shards from Hugging Face. If you already have them in a
# ramalama store, this links the store's blobs into a folder Strata can use as
# --gguf-dir, so the ~70 GB download is skipped. The shards are read through the
# symlinks (Strata verifies each against its own GGUF tensor directory).
#
# Usage:
#   import_from_ramalama.sh 'hf://ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0'
#   ./setup.sh --family qwen --model Q2_0 --gguf-dir ~/.strata/gguf
#
# Environment:
#   STRATA_RAMALAMA_STORE  the ramalama store root (default /usr/local/storage/ramalama/store)
#   STRATA_GGUF_DIR        the --gguf-dir to build (default ~/.strata/gguf)
set -euo pipefail

STORE="${STRATA_RAMALAMA_STORE:-/usr/local/storage/ramalama/store}"
DEST="${STRATA_GGUF_DIR:-$HOME/.strata/gguf}"

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
echo "gguf-dir ready: $DEST"
ls -la "$DEST"
echo
echo "start it with:"
echo "  ./setup.sh --family qwen --model Q2_0 --gguf-dir $DEST"
