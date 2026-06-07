"""
data-generator: oracle-src の src_schema に継続的に DML を発行する
- python-oracledb thin mode（Oracle Instant Client 不要）
- 強度: LOW(10s/1-3rows) / MEDIUM(5s/5-10rows) / HIGH(1s/20-50rows)
- 環境変数: DB_HOST, DB_PORT, DB_SERVICE, DB_USER, DB_PASS, GENERATOR_INTENSITY
"""
import os
import signal
import sys
import time
import threading
import traceback

import oracledb

from workload import customers, orders, products, contracts, events
from init import seed_master

INTENSITY_CONFIG = {
    "LOW":    {"sleep_sec": 10, "batch_min": 1,  "batch_max": 3,  "blob_kb": 1},
    "MEDIUM": {"sleep_sec": 5,  "batch_min": 5,  "batch_max": 10, "blob_kb": 10},
    "HIGH":   {"sleep_sec": 1,  "batch_min": 20, "batch_max": 50, "blob_kb": 100},
}

_stop_event = threading.Event()


def make_dsn() -> str:
    host    = os.environ.get("DB_HOST",    "oracle-src")
    port    = os.environ.get("DB_PORT",    "1521")
    service = os.environ.get("DB_SERVICE", "XEPDB1")
    return f"{host}:{port}/{service}"


def connect() -> oracledb.Connection:
    dsn  = make_dsn()
    user = os.environ.get("DB_USER", "src_schema")
    pw   = os.environ.get("DB_PASS", "srcpass1")
    return oracledb.connect(user=user, password=pw, dsn=dsn)


def wait_for_db(max_wait_sec: int = 300) -> None:
    print("Waiting for oracle-src to become available...", flush=True)
    start = time.monotonic()
    while not _stop_event.is_set():
        try:
            conn = connect()
            conn.close()
            print("oracle-src is available.", flush=True)
            return
        except Exception as e:
            elapsed = time.monotonic() - start
            if elapsed >= max_wait_sec:
                print(f"Timeout waiting for oracle-src: {e}", flush=True)
                sys.exit(1)
            time.sleep(5)


def run_workloads(cfg: dict) -> None:
    while not _stop_event.is_set():
        try:
            conn = connect()
            try:
                customers.run(conn, cfg)
                orders.run(conn, cfg)
                products.run(conn, cfg)
                contracts.run(conn, cfg)
                events.run(conn, cfg)
                conn.commit()
            finally:
                conn.close()
        except Exception:
            print("Workload error (will retry):", traceback.format_exc(), flush=True)

        _stop_event.wait(cfg["sleep_sec"])


def handle_signal(sig, frame) -> None:
    print(f"Received signal {sig}. Shutting down gracefully...", flush=True)
    _stop_event.set()


def main() -> None:
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT,  handle_signal)

    intensity = os.environ.get("GENERATOR_INTENSITY", "MEDIUM").upper()
    cfg = INTENSITY_CONFIG.get(intensity, INTENSITY_CONFIG["MEDIUM"])
    print(f"Starting data-generator [intensity={intensity}]", flush=True)

    wait_for_db()

    # 初期マスタデータ投入（冪等）
    try:
        conn = connect()
        try:
            seed_master.seed(conn)
            conn.commit()
            print("Master data seeded.", flush=True)
        finally:
            conn.close()
    except Exception:
        print("Seed error:", traceback.format_exc(), flush=True)

    run_workloads(cfg)
    print("data-generator stopped.", flush=True)


if __name__ == "__main__":
    main()
