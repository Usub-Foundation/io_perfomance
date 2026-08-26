#!/usr/bin/env bash
set -euo pipefail

BIN=${1:-"./build/echo_uvent"}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-28000}   # below ip_local_port_range: wrk's 1000 client ports must not collide with the next server port
THREADS=${THREADS:-4}
# wrk needs more threads than a 1-2 thread server or it becomes the bottleneck itself
WRK_THREADS=${WRK_THREADS:-$(( THREADS > 4 ? THREADS : 4 ))}
# keep wrk off the server's cores AND their SMT siblings (a pinned worker sharing a physical core with a
# wrk thread loses ~6% RPS and doubles p99); e.g. WRK_CPUS=5-9,15-19 on a 10c/20t box for servers up to 4 threads
WRK_CPUS=${WRK_CPUS:-}
WRK=(wrk); [[ -n "$WRK_CPUS" ]] && WRK=(taskset -c "$WRK_CPUS" wrk)
CONN=${CONN:-1000}
DUR=${DUR:-30s}
WARMUP=${WARMUP:-0s}
REUSE=${REUSE:-0}
READY_TIMEOUT=${READY_TIMEOUT:-10}
STOP_TIMEOUT=${STOP_TIMEOUT:-5}

mkdir -p logs results
# refuse to run next to a stray server from a previous run (it would share the port via SO_REUSEPORT and burn CPU)
if pgrep -f '/echo_(uvent|uring|asio|libuv) --host' >/dev/null; then echo "stray benchmark server running: $(pgrep -af '/echo_(uvent|uring|asio|libuv) --host')"; exit 1; fi
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

[[ "$WARMUP" != "0s" ]] && "${WRK[@]}" -t"$WRK_THREADS" -c"$CONN" -d"$WARMUP" "http://$HOST:$PORT/" >/dev/null || true

OUT="results/${name}_t${THREADS}_c${CONN}_r${REUSE}_p${PORT}_${ts}.txt"
echo "bench -> $OUT"
"${WRK[@]}" -t"$WRK_THREADS" -c"$CONN" -d"$DUR" --latency "http://$HOST:$PORT/" | tee "$OUT"

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