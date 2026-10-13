#!/usr/bin/env bash
# Lab 1 - Part B: starts misbehaving processes on YOUR machine so you can find them.
# Everything runs as your user, inside ./chaos-tmp, and is stopped by ./chaos.sh stop
# Requirements: bash, python3 (Linux or WSL2; macOS works except /proc-based tasks)
set -euo pipefail
cd "$(dirname "$0")"
WORK="$PWD/chaos-tmp"
PIDS="$WORK/.pids"

start() {
  mkdir -p "$WORK"
  : > "$PIDS"

  # 1) "report-worker": burns one CPU core
  nohup bash -c 'exec -a report-worker python3 -c "while True: pass"' >/dev/null 2>&1 &
  echo $! >> "$PIDS"

  # 2) "feed-listener": leaks file descriptors (opens a new file every second, never closes)
  nohup bash -c "exec -a feed-listener python3 -c '
import time, os
handles = []
os.makedirs(\"$WORK/feed\", exist_ok=True)
i = 0
while True:
    handles.append(open(\"$WORK/feed/msg-%06d.tmp\" % i, \"w\"))
    i += 1
    time.sleep(1)
'" >/dev/null 2>&1 &
  echo $! >> "$PIDS"

  # 3) "legacy-admin": squats port 8080, so the real app cannot start
  nohup bash -c "exec -a legacy-admin python3 -m http.server 8080 --bind 127.0.0.1 --directory $WORK" >/dev/null 2>&1 &
  echo $! >> "$PIDS"

  # 4) "audit-writer": writes a big log, then the file is deleted while still open.
  #    Classic: disk space is not released, 'du' doesn't see it, 'df' does.
  nohup bash -c "exec -a audit-writer python3 -c '
import os, time
p = \"$WORK/audit.log\"
f = open(p, \"wb\")
f.write(os.urandom(150 * 1024 * 1024))
f.flush()
os.remove(p)
while True:
    f.write(b\"audit event\\n\" * 1000); f.flush(); time.sleep(2)
'" >/dev/null 2>&1 &
  echo $! >> "$PIDS"

  # 5) "nightly-recon": a memory hog that grows to ~600 MB then sleeps
  nohup bash -c "exec -a nightly-recon python3 -c '
import time
blob = []
for _ in range(60):
    blob.append(bytearray(10 * 1024 * 1024)); time.sleep(0.5)
while True: time.sleep(60)
'" >/dev/null 2>&1 &
  echo $! >> "$PIDS"

  sleep 2
  echo "Chaos started. Something is wrong on this box. Go find it (see README.md, Part B)."
}

stop() {
  if [[ -f "$PIDS" ]]; then
    while read -r p; do kill "$p" 2>/dev/null || true; done < "$PIDS"
  fi
  pkill -f '^(report-worker|feed-listener|legacy-admin|audit-writer|nightly-recon) ' 2>/dev/null || true
  rm -rf "$WORK"
  echo "Chaos stopped and cleaned."
}

case "${1:-start}" in
  start) start ;;
  stop)  stop ;;
  *) echo "usage: $0 [start|stop]"; exit 1 ;;
esac
