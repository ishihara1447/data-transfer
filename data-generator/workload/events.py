"""
events.py: SYSTEM_EVENTS への高頻度 INSERT ONLY
FK なし独立テーブル。CDC 検証のベースラインとして最もシンプルな検証基準。
"""
import json
import random
import oracledb
from faker import Faker

_fake = Faker("ja_JP")

EVENT_TYPES  = ["ORDER_CREATED", "ORDER_SHIPPED", "PAYMENT_PROCESSED",
                "CUSTOMER_UPDATED", "CDC_LAG_ALERT", "SYSTEM_ERROR",
                "PRODUCT_UPDATED", "CONTRACT_SIGNED"]
SEVERITIES   = ["DEBUG", "INFO", "INFO", "INFO", "WARN", "ERROR"]
SOURCES      = ["web-api", "batch-job", "data-generator", "scheduler"]


def run(conn: oracledb.Connection, cfg: dict) -> None:
    # SYSTEM_EVENTS は高頻度挿入なので batch の2倍を発行
    batch = random.randint(cfg["batch_min"], cfg["batch_max"]) * 2

    sql = """
        INSERT INTO src_schema.system_events (
            event_type, source_system, severity, message, event_payload
        ) VALUES (
            :etype, :source, :sev, :msg, :payload
        )
    """
    with conn.cursor() as cur:
        for _ in range(batch):
            payload = json.dumps({
                "timestamp":  _fake.iso8601(),
                "request_id": _fake.uuid4(),
                "user_id":    random.randint(1, 10000),
                "details":    _fake.sentence(),
            }, ensure_ascii=False)
            cur.execute(sql, {
                "etype":   random.choice(EVENT_TYPES),
                "source":  random.choice(SOURCES),
                "sev":     random.choice(SEVERITIES),
                "msg":     _fake.sentence()[:200],
                "payload": payload,
            })
