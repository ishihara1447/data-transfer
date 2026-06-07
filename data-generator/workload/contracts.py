"""
contracts.py: CUSTOMER_CONTRACTS への INSERT/UPDATE/DELETE
contract_pdf BLOB / signed_image BLOB / contract_text CLOB の重負荷テスト
CDC 検証の最重要ポイント: 複数 BLOB カラムの redo log 記録精度の確認
"""
import os
import random
import oracledb
from faker import Faker

_fake = Faker("ja_JP")

CONTRACT_TYPES = ["BASIC", "PREMIUM", "ENTERPRISE"]


def _customer_ids(conn) -> list:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT customer_id FROM src_schema.customers "
            "WHERE status = 'ACTIVE' AND ROWNUM <= 200"
        )
        rows = cur.fetchall()
    return [r[0] for r in rows] if rows else []


def run(conn: oracledb.Connection, cfg: dict) -> None:
    batch = random.randint(cfg["batch_min"], cfg["batch_max"])
    blob_size = cfg["blob_kb"] * 1024
    customer_ids = _customer_ids(conn)
    if not customer_ids:
        return

    for _ in range(batch):
        action = random.choices(["insert", "update", "delete"], weights=[50, 35, 15])[0]

        if action == "insert":
            _insert(conn, customer_ids, blob_size)
        elif action == "update":
            _update(conn, blob_size)
        else:
            _delete(conn)


def _insert(conn, customer_ids, blob_size: int) -> None:
    cust_id       = random.choice(customer_ids)
    contract_text = _fake.paragraph(nb_sentences=20)
    contract_pdf  = os.urandom(max(512, blob_size))
    signed_image  = os.urandom(max(256, blob_size // 2))

    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO src_schema.customer_contracts (
                customer_id, contract_type, contract_no,
                start_date, end_date, status,
                contract_text, contract_pdf, signed_image, created_by
            ) VALUES (
                :cust_id, :ctype,
                :cno,
                TRUNC(SYSDATE),
                ADD_MONTHS(TRUNC(SYSDATE), 12),
                'ACTIVE',
                :ctext, :cpdf, :simg, 'data-generator'
            )
        """, {
            "cust_id": cust_id,
            "ctype":   random.choice(CONTRACT_TYPES),
            "cno":     f"CN{random.randint(10000000, 99999999)}",
            "ctext":   contract_text,
            "cpdf":    contract_pdf,
            "simg":    signed_image,
        })


def _update(conn, blob_size: int) -> None:
    signed_image = os.urandom(max(256, blob_size // 2))
    with conn.cursor() as cur:
        cur.execute("""
            UPDATE src_schema.customer_contracts
            SET signed_image = :simg, updated_at = SYSTIMESTAMP
            WHERE contract_id = (
                SELECT contract_id FROM (
                    SELECT contract_id FROM src_schema.customer_contracts
                    WHERE status = 'ACTIVE'
                    ORDER BY DBMS_RANDOM.VALUE
                ) WHERE ROWNUM = 1
            )
        """, {"simg": signed_image})


def _delete(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("""
            DELETE FROM src_schema.customer_contracts
            WHERE contract_id = (
                SELECT contract_id FROM (
                    SELECT contract_id FROM src_schema.customer_contracts
                    WHERE status IN ('EXPIRED', 'TERMINATED')
                    ORDER BY DBMS_RANDOM.VALUE
                ) WHERE ROWNUM = 1
            )
        """)
