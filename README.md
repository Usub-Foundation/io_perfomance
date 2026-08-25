# io_perfomance

Reproducible throughput/latency comparison of async I/O libraries on the same minimal workload — an HTTP/1.1 keep-alive
"echo" server hammered by [wrk](https://github.com/wg/wrk).

Servers under test (`src/echo_tcp/`):

| Binary       | Library                                                              | Threading model                                                                            |
|--------------|----------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| `echo_uvent` | [uvent](https://github.com/Usub-Foundation/uvent) (C++23 coroutines) | N worker threads, one `TCPServerSocket` acceptor per thread (`SO_REUSEPORT`)               |
| `echo_asio`  | Boost.Asio (callbacks)                                               | one `io_context`, N threads calling `run()`                                                |
| `echo_libuv` | libuv 1.49 (C callbacks)                                             | N independent `uv_loop_t`, one per thread, each with its own listener (`UV_TCP_REUSEPORT`) |

Every server reads a request, answers a fixed 20-byte JSON body, keeps the connection open. No parsing, no allocation
per
request — the numbers measure the event loop and syscall path, nothing else.

## Results

| Threads | uvent RPS | Boost.Asio RPS | libuv RPS | uvent p99 | Boost.Asio p99 | libuv p99 | runs |
|--------:|----------:|---------------:|----------:|----------:|---------------:|----------:|-----:|
|       1 |   107,647 |        113,537 |   113,503 |   8.94 ms |        6.03 ms |   6.53 ms |    1 |
|       2 |   209,711 |        209,883 |   210,899 |   4.83 ms |        4.41 ms |   4.77 ms |    1 |
|       4 |   381,159 |        384,020 |   386,309 |   3.28 ms |        2.67 ms |   2.75 ms |    1 |
|       8 |   541,207 |        498,647 |   588,272 |   2.01 ms |        2.36 ms |   2.68 ms |    3 |

![Mean RPS vs threads](images/rps_mean.png)

Host: 1× Intel Xeon E5-2640 v4 (10 cores / 20 threads, 2.4 GHz), Linux 6.8, GCC 13.3, `-O3 -march=native` + LTO;
uvent `f678513` (epoll backend), Boost 1.83, libuv 1.49.2. `wrk -t<threads> -c1000 -d30s --latency`, 3 s warm-up.
Cells with `runs = 3` are the mean of three runs (spread < 4 %), the rest are single runs.
Raw `wrk` output is in `results/` on the machine that ran it; the CSV behind the table is `images/summary_agg.csv`.

Reading: up to 4 threads all three are within 2–5 % — the loop is not the bottleneck on this workload. At 8 threads
libuv leads (~588k), uvent follows (~541k, lowest p99), Boost.Asio's single shared `io_context` trails (~499k).
Earlier versions of this repo showed libuv at a few hundred RPS. That was an artifact of the old single-loop
`echo_libuv` and how it was run, not a property of libuv; the server has been rewritten (one loop per thread,
`UV_TCP_REUSEPORT`) and every number above was re-measured with it.

## Build

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release -DWITH_UVENT=ON -DWITH_ASIO=ON -DWITH_LIBUV=ON -DENABLE_LTO=ON
cmake --build build -j
```

uvent and libuv are fetched with `FetchContent`; Boost must be installed (`libboost-system-dev` or equivalent).

## Run

```bash
chmod +x scripts/*.sh
ulimit -n 65535                      # 1000 connections + wrk on the same host
```

All libraries, full thread matrix (one `wrk` run per cell, results in `results/*.txt`, server logs in `logs/`):

```bash
THREADS_LIST="1 2 4 8" CONN=1000 DUR=30s WARMUP=3s scripts/run_all.sh
```

One library:

```bash
THREADS=8 CONN=1000 DUR=30s scripts/run_one.sh ./build/echo_libuv
```

`run_one.sh` starts the server, waits for the port, runs `wrk -t$THREADS -c$CONN -d$DUR --latency`, then stops the
server. `--threads N` is passed to every binary, so all three scale on the same terms.

For a quieter box see `scripts/sys_tune_example.sh` (somaxconn, syn backlog, `tcp_tw_reuse`).

## Summarize & plot

```bash
scripts/summarize.sh                                   # results/*.txt -> results/summary.csv
python3 -m venv .venv && .venv/bin/pip install pandas matplotlib
.venv/bin/python scripts/analyze.py --in results/summary.csv --out images --max-threads 8
```

`analyze.py` writes `rps_mean.png`, `rps_median.png`, `p99_vs_threads.png` (several runs per cell are averaged).

## Caveats

- `wrk` runs on the same host as the server, so at high thread counts the load generator competes for cores; keep
  `THREADS × 2 ≤ physical cores` for clean numbers, or run `wrk` from a second machine.
- This is a best-case, parse-free workload. It says nothing about HTTP parsing, TLS, or application logic — only about
  how
  cheaply each library moves bytes through `epoll`.
- Single 30 s runs; expect a few percent of jitter. Repeat and average before drawing conclusions from small deltas.
