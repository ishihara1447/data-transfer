"""
products.py: PRODUCTS 更新 + PRICE_HISTORY INSERT
価格変更(is_discontinued=0 の商品) → PRICE_HISTORY に履歴を追記
"""
import os
import random
import oracledb
from faker import Faker

_fake = Faker("ja_JP")


def run(conn: oracledb.Connection, cfg: dict) -> None:
    batch = random.randint(cfg["batch_min"], cfg["batch_max"])
    blob_size = cfg["blob_kb"] * 1024

    with conn.cursor() as cur:
        cur.execute("""
            SELECT product_id, unit_price FROM (
                SELECT product_id, unit_price FROM src_schema.products
                WHERE is_discontinued = 0
                ORDER BY DBMS_RANDOM.VALUE
            ) WHERE ROWNUM <= :n
        """, {"n": batch})
        rows = cur.fetchall()

    for pid, old_price in rows:
        change_pct = random.uniform(-0.1, 0.15)
        new_price  = max(1.0, min(9999999.99, round(float(old_price) * (1 + change_pct), 2)))
        thumbnail  = os.urandom(max(64, blob_size // 4))
        spec_json  = _fake.paragraph(nb_sentences=3)

        with conn.cursor() as cur:
            cur.execute("""
                UPDATE src_schema.products
                SET unit_price = :new_price,
                    thumbnail  = :thumb,
                    spec_json  = :spec,
                    updated_at = SYSTIMESTAMP
                WHERE product_id = :pid
            """, {"new_price": new_price, "thumb": thumbnail,
                  "spec": spec_json, "pid": pid})

            cur.execute("""
                INSERT INTO src_schema.price_history (
                    product_id, old_price, new_price,
                    changed_by, effective_date
                ) VALUES (
                    :pid, :old_price, :new_price,
                    'data-generator', TRUNC(SYSDATE)
                )
            """, {"pid": pid, "old_price": old_price, "new_price": new_price})
