#!/usr/bin/env bash
set -euo pipefail

BIN=${1:-"./build/echo_uvent"}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-45900}
THREADS=${THREADS:-4}
CONN=${CONN:-1000}
DUR=${DUR:-30s}
WARMUP=${WARMUP:-0s}
REUSE=${REUSE:-0}
READY_TIMEOUT=${READY_TIMEOUT:-10}
STOP_TIMEOUT=${STOP_TIMEOUT:-5}

mkdir -p logs results
name=$(basename "$BIN")
ts=$(date +"%Y%m%d_%H%M%S")
LOG="logs/${name}_t${THREADS}_p${PORT}_${ts}.log"

ARGS=(--host "$HOST" --port "$PORT")
ARGS+=(--threads "$THREADS")
[[ "$REUSE" == "1" ]] && ARGS+=(--reuseport)

setsid stdbuf -oL -eL "$BIN" "${ARGS[@]}" >"$LOG" 2>&1 &
SRV_PID=$!
SRV_PGID=$(ps -o pgid= "$SRV_PID" | tr -d ' ')
echo "started $name pid=$SRV_PID pgid=$SRV_PGID args=${ARGS[*]} (log: $LOG)"

ready=0
for _ in $(seq 1 $READY_TIMEOUT); do
  if (exec 3<>/dev/tcp/"$HOST"/"$PORT") 2>/dev/null; then exec 3>&-; ready=1; break; fi
  sleep 1
done
[[ $ready -eq 1 ]] || { echo "server not ready on $HOST:$PORT"; tail -n 100 "$LOG" || true; exit 1; }

[[ "$WARMUP" != "0s" ]] && wrk -t"$THREADS" -c"$CONN" -d"$WARMUP" "http://$HOST:$PORT/" >/dev/null || true

OUT="results/${name}_t${THREADS}_c${CONN}_r${REUSE}_p${PORT}_${ts}.txt"
echo "bench -> $OUT"
wrk -t"$THREADS" -c"$CONN" -d"$DUR" --latency "http://$HOST:$PORT/" | tee "$OUT"

stop_group() {
  local sig="$1" msg="$2"
  echo "stopping pgid=$SRV_PGID with $msg"
  kill "-$sig" "-$SRV_PGID" 2>/dev/null || true
  for _ in $(seq 1 "$STOP_TIMEOUT"); do
    kill -0 "$SRV_PID" 2>/dev/null || return 0
    sleep 1
  done
  return 1
}

stop_group INT  "SIGINT"  || \
stop_group TERM "SIGTERM" || \
stop_group KILL "SIGKILL"

pkill -P "$SRV_PID" 2>/dev/null || true
wait "$SRV_PID" 2>/dev/null || true

echo "stopped. last log lines:"
tail -n 20 "$LOG" || true