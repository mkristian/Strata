#!/usr/bin/env bash
# serve-orca.sh - start and stop the OrcaRouter IQ3_XXS server from docs/ORCA.md.
#
# The Terminal has no Orca path (docs/ORCA.md: "there is no --family orca command"), so this model is
# served straight from its engine config. This script checks the pack and the shards first, then starts
# `python -m serve.server` in the background and remembers its PID, so stopping it needs no hunting.
#
#   ./serve-orca.sh check    validate the pack, the shards and the engine; change nothing
#   ./serve-orca.sh run      validate, serve in the background, then open the seven-view Terminal monitor
#                            (`strata monitor`) against it - the TUI `strata launch` opens, on this server
#   ./serve-orca.sh start    validate, then serve in the background and print the PID
#   ./serve-orca.sh status   is it running, where to reach it, the last log lines
#   ./serve-orca.sh stop     TERM, then KILL after 15s
#
# Paths, port and log are read from the config file, so the two never drift apart. The monitor is
# read-only and needs Textual: pip install -r requirements-monitor.txt.
set -euo pipefail

CFG=${CFG:-strata-orca-iq3_xxs.json}
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PIDFILE=$ROOT/.serve-orca.pid
cd "$ROOT"

# The server and the packing tool need a Python with the repo's dependencies: the venv first.
pick_python() {
  if [ -n "${STRATA_PYTHON:-}" ] && [ -x "$STRATA_PYTHON" ]; then printf '%s\n' "$STRATA_PYTHON"; return 0; fi
  if [ -x "$ROOT/.venv/bin/python" ]; then printf '%s\n' "$ROOT/.venv/bin/python"; return 0; fi
  if command -v python3 >/dev/null 2>&1; then printf '%s\n' python3; return 0; fi
  echo "no Python found (expected .venv/bin/python); build Strata first: docs/SOURCE_INSTALL.md" >&2
  return 1
}

# One config file, read once: pack, tokenizer, exe, host, port, log, mtp, native, ple-gguf - one per line.
cfg_fields() {
  "$1" - "$CFG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
a = c.get("args", [])
def get(flag, default=""):
    return a[a.index(flag) + 1] if flag in a else default
for v in [get("--pack"), c.get("tokenizer", ""), c.get("exe", ""), c.get("host", "127.0.0.1"),
          str(c.get("port", 8095)), c.get("log", "strata-orca.log"), get("--mtp"),
          get("--native"), get("--ple-gguf")]:
    print(v)
PY
}

bad=0
bad()  { printf '  NO   %s\n' "$1"; bad=$((bad + 1)); }
ok()   { printf '  ok   %s\n' "$1"; }
warn() { printf '  warn %s\n' "$1"; }
note() { printf '       %s\n' "$1"; }

# (1) the config, (2) the pack, (3) the engine, (4) the shards, (5) RAM. All findings are listed at once.
check() {
  local py pack tok exe host port log mtp native ple n i sfx stem avail
  py=$(pick_python) || return 1
  if [ ! -f "$CFG" ]; then bad "config $CFG is missing"; return 1; fi
  ok "config $CFG"
  mapfile -t F < <(cfg_fields "$py")
  if [ "${#F[@]}" -lt 9 ]; then bad "config $CFG cannot be read with $py (is it a JSON file from docs/ORCA.md?)"; return 1; fi
  pack=${F[0]} tok=${F[1]} exe=${F[2]} host=${F[3]} port=${F[4]} log=${F[5]} mtp=${F[6]} native=${F[7]} ple=${F[8]}
  note "pack   $pack"
  note "shard  $native"
  if [ -n "$native" ] && [ "$native" = "$ple" ]; then
    ok "--native and --ple-gguf name the same shard (the PLE table is in shard 1)"
  else
    warn "--native and --ple-gguf differ; docs/ORCA.md points both at the first shard"
  fi

  # The pack. native_experts.txt is written LAST by tools/iq_pack.py ("a pack without it is not
  # finished"), so a lone compat-bf16.json does not prove the pack is complete.
  if [ -f "$pack/native_experts.txt" ]; then
    ok "native_experts.txt ($(head -n 1 "$pack/native_experts.txt" | cut -c1-46)…)"
  else
    bad "native_experts.txt is missing: the packing was interrupted, run tools/iq_pack.py again"
  fi
  for f in index.txt dense.bin conversions.json; do
    if [ -f "$pack/$f" ]; then ok "$f"; else bad "$f is missing from the pack"; fi
  done
  if [ -f "$pack/compat-bf16.json" ]; then
    ok "compat-bf16.json"
    grep -q 'nearest-even' "$pack/compat-bf16.json" || warn "compat-bf16.json records no nearest-even rounding"
  else
    warn "compat-bf16.json is missing: the pack was built without --compat-bf16 (docs/ORCA.md requires it)"
  fi
  if [ -f "$tok/vocab.json" ] && [ -f "$tok/chat_template.jinja" ]; then
    ok "tokenizer (vocab.json + chat_template.jinja)"
  else
    bad "tokenizer incomplete in $tok (needs vocab.json and chat_template.jinja)"
  fi
  if [ -e "$pack/experts.bin" ]; then
    warn "experts.bin exists: the engine reads it instead of the GGUF (docs/ORCA.md reads the experts from the shards)"
  else
    ok "no experts.bin (the experts are read from the GGUF)"
  fi
  if [ -n "$mtp" ] && [ -f "$mtp/experts.bin" ]; then
    ok "MTP draft head $mtp"
  elif [ -n "$mtp" ]; then
    bad "--mtp is in the config but $mtp/experts.bin is missing: build it (docs/ORCA.md, Preparation) or drop --mtp"
  else
    warn "no --mtp in the config: the server drafts by lookup only"
  fi

  # The engine the config runs, and the Python the server runs on (serve/server.py imports regex at start).
  if [ -x "$exe" ]; then ok "engine $exe"; else bad "engine $exe is missing or not executable (build Strata: docs/SOURCE_INSTALL.md)"; fi
  if "$py" -c 'import regex' >/dev/null 2>&1; then ok "Python $py has regex (the server needs it)"; else bad "Python $py has no regex: build the venv (docs/SOURCE_INSTALL.md) or set STRATA_PYTHON"; fi

  # Every shard, by the name tools/iq_pack.py and the engine use: -0000N-of-0000M.
  n=$(basename "$native" | sed -n 's/.*-0*[0-9]\+-of-0*\([0-9]\+\)\.gguf$/\1/p')
  stem=${native%-*-*-*.gguf}   # drop the "-00001-of-00002.gguf" tail, keep the folder and the model name
  if [ -z "$n" ]; then
    warn "shard 1's name has no -0000N-of-0000M part, so the shards cannot be found by name"
  else
    n=$((10#$n))
    for ((i = 1; i <= n; i++)); do
      sfx=$(printf '%05d' "$i")
      if [ -f "${stem}-${sfx}-of-$(printf '%05d' "$n").gguf" ]; then
        ok "shard $i of $n"
      else
        bad "shard $i of $n is missing beside shard 1 (${stem}-${sfx}-of-…)"
      fi
    done
  fi
  if [ -f "$native" ]; then ok "shard 1 exists ($(du -h "$native" | cut -f1))"; else bad "shard 1 is missing: $native"; fi

  # RAM: docs/ORCA.md measured about 49.8 GiB free system RAM for the expert arena.
  avail=$(awk '/MemAvailable/ { print int($2 / 1048576) }' /proc/meminfo 2>/dev/null || echo 0)
  if [ "${avail:-0}" -ge 50 ]; then ok "RAM: ${avail} GB available"
  else warn "RAM: ${avail:-0} GB available; docs/ORCA.md needs about 49.8 GiB free for the expert arena"; fi

  [ "$bad" = 0 ]
}

running() {
  [ -f "$PIDFILE" ] || return 1
  local pid; pid=$(cat "$PIDFILE") || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # A bare PID can be reused by an unrelated process. Confirm it is really our server, by its own command
  # line, before status calls it "serving" and before stop sends it a signal.
  if [ -r "/proc/$pid/cmdline" ]; then
    if tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q -- "serve.server" \
       && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q -- "$(basename "$CFG")"; then
      printf '%s\n' "$pid"; return 0
    fi
    rm -f "$PIDFILE"; return 1
  fi
  printf '%s\n' "$pid"   # no /proc (Mac): the PID is all there is
}

case ${1:-check} in
  check)
    echo "checking the Orca IQ3_XXS server in $ROOT"
    check || { echo; echo "not ready: fix the NO lines above"; exit 1; }
    echo; echo "ready: $0 start"
    ;;
  run)
    check || { echo; echo "not started: fix the NO lines above"; exit 1; }
    py=$(pick_python)
    mapfile -t F < <(cfg_fields "$py")
    if [ "${#F[@]}" -lt 9 ]; then echo "config $CFG cannot be read with $py"; exit 1; fi
    host=${F[3]:-127.0.0.1}; port=${F[4]:-8095}; log=${F[5]:-strata-orca.log}
    if ! "$py" -c 'import textual, rich' >/dev/null 2>&1; then
      echo "the monitor TUI needs Textual and rich: pip install -r requirements-monitor.txt"
      echo "the server runs without them: $0 start   one snapshot: sh $ROOT/bin/strata monitor --url http://${host}:${port} --once"
      exit 1
    fi
    if pid=$(running); then
      echo "already serving (PID $pid)"
    else
      echo "starting the server …"
      nohup "$py" -m serve.server --engine strata --config "$CFG" --port "$port" >"$log.serve" 2>&1 &
      echo $! >"$PIDFILE"
      echo "server PID $(cat "$PIDFILE")   engine log: $log   server output: $log.serve"
    fi
    # The same Python runs the monitor, so the Textual check above is the Python the TUI starts in.
    export STRATA_PYTHON=$py
    url="http://${host}:${port}"
    echo "waiting for the API at $url (the model loads first) …"
    ready=0
    for _ in $(seq 1 120); do
      if sh "$ROOT/bin/strata" monitor --url "$url" --once --quiet >/dev/null 2>&1; then ready=1; break; fi
      if ! running >/dev/null; then
        rm -f "$PIDFILE"
        echo "the server exited; its last output:"; tail -n 15 "$log.serve" 2>/dev/null; exit 1
      fi
      sleep 2
    done
    if [ "$ready" != 1 ]; then echo "the API did not answer within 4 minutes; see $log and $log.serve"; exit 1; fi
    echo "opening the monitor: Ctrl+C quits it, the server keeps serving"
    cred=""
    [ -n "${STRATA_API_KEY:-}" ] && cred="--credential-env STRATA_API_KEY"
    # shellcheck disable=SC2086
    sh "$ROOT/bin/strata" monitor --url "$url" $cred --interval 1
    echo "monitor closed. Serving at $url (PID $(cat "$PIDFILE")); stop it: $0 stop"
    ;;
  start)
    check || { echo; echo "not started: fix the NO lines above"; exit 1; }
    if pid=$(running); then echo "already serving (PID $pid); stop it first: $0 stop"; exit 1; fi
    py=$(pick_python)
    mapfile -t F < <(cfg_fields "$py")
    if [ "${#F[@]}" -lt 9 ]; then echo "config $CFG cannot be read with $py"; exit 1; fi
    log=${F[5]:-strata-orca.log}; port=${F[4]:-8095}
    echo "starting the server …"
    nohup "$py" -m serve.server --engine strata --config "$CFG" --port "$port" >"$log.serve" 2>&1 &
    echo $! >"$PIDFILE"
    echo "PID $(cat "$PIDFILE")   engine log: $log   server output: $log.serve"
    echo "the model loads for a while; watch: $0 status   page: http://127.0.0.1:$port"
    ;;
  status)
    if pid=$(running); then
      py=$(pick_python); mapfile -t F < <(cfg_fields "$py")
      if [ "${#F[@]}" -lt 9 ]; then echo "config $CFG cannot be read with $py"; exit 1; fi
      log=${F[5]:-strata-orca.log}; port=${F[4]:-8095}; host=${F[3]:-127.0.0.1}
      echo "serving, PID $pid"
      echo "web: http://${host}:${port}   api: http://${host}:${port}/v1"
      echo "--- last 20 lines of $log ---"
      tail -n 20 "$log" 2>/dev/null || echo "(no log lines yet)"
    else
      echo "not serving (no live PID in $PIDFILE)"
    fi
    ;;
  stop)
    if pid=$(running); then
      echo "stopping PID $pid …"
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      if kill -0 "$pid" 2>/dev/null; then
        # serve.server shuts its engine tree down on SIGTERM; a stuck tree gets a KILL after 15s.
        echo "still alive after 15s; sending KILL"
        kill -9 "$pid" 2>/dev/null || true
      fi
      rm -f "$PIDFILE"; echo "stopped"
    else
      echo "not serving"; rm -f "$PIDFILE"
    fi
    ;;
  *)
    echo "usage: $0 [check|start|status|stop]" >&2; exit 2
    ;;
esac
