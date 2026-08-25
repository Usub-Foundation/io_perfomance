#!/usr/bin/env bash
# results/*.txt (wrk --latency output) -> results/summary.csv
set -euo pipefail
echo "bin,threads,conn,port,rps,p50,p75,p90,p99" > results/summary.csv
for f in results/*.txt; do
  bin=$(basename "$f" | cut -d_ -f1-2 | sed 's/_$//')
  threads=$(grep -oE '_t[0-9]+' <<<"$f" | tr -dc 0-9)
  conn=$(   grep -oE '_c[0-9]+' <<<"$f" | tr -dc 0-9)
  port=$(   grep -oE '_p[0-9]+' <<<"$f" | tr -dc 0-9)
  rps=$(grep -E '^Requests/sec:' "$f" | awk '{print $2}' || true)
  [[ -n "$rps" ]] || { echo "skip $f (no Requests/sec)"; continue; }
  # wrk prints:  Latency Distribution / 50% / 75% / 90% / 99%
  pct() { grep -A4 '^  Latency Distribution' "$f" | awk -v want="$1" '$1==want {print $2}' || true; }
  echo "$bin,$threads,$conn,$port,$rps,$(pct 50%),$(pct 75%),$(pct 90%),$(pct 99%)" >> results/summary.csv
done
echo "Wrote results/summary.csv"
