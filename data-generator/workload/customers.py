"""
customers.py: CUSTOMERS テーブルへの INSERT/UPDATE/DELETE 発行
INSERT(30%) / UPDATE remarks CLOB(50%) / DELETE CLOSED 顧客(20%)
BLOB(avatar_image): cfg["blob_kb"] KB のランダムバイナリ
"""
import os
import random
import oracledb
from faker import Faker

_fake = Faker("ja_JP")


def _region_ids(conn) -> list:
    with conn.cursor() as cur:
        cur.execute("SELECT region_id FROM src_schema.regions WHERE is_active = 1")
        rows = cur.fetchall()
    return [r[0] for r in rows] if rows else [None]


def run(conn: oracledb.Connection, cfg: dict) -> None:
    batch = random.randint(cfg["batch_min"], cfg["batch_max"])
    blob_size = cfg["blob_kb"] * 1024
    region_ids = _region_ids(conn)

    for _ in range(batch):
        action = random.choices(["insert", "update", "delete"], weights=[30, 50, 20])[0]

        if action == "insert":
            _insert(conn, region_ids, blob_size)
        elif action == "update":
            _update(conn)
        else:
            _delete(conn)


def _insert(conn, region_ids, blob_size: int) -> None:
    avatar = os.urandom(max(64, blob_size))
    remarks = _fake.paragraph(nb_sentences=5)
    sql = """
        INSERT INTO src_schema.customers (
            customer_code, company_name, last_name, first_name,
            email, phone, region_id, credit_limit, status,
            avatar_image, remarks
        ) VALUES (
            :code, :company, :last_name, :first_name,
            :email, :phone, :region_id, :credit, 'ACTIVE',
            :avatar, :remarks
        )
    """
    with conn.cursor() as cur:
        cur.execute(sql, {
            "code":      f"C{random.randint(100000, 999999)}",
            "company":   _fake.company(),
            "last_name": _fake.last_name(),
            "first_name":_fake.first_name(),
            "email":     f"u{random.randint(1,999999)}@example-gen.com",
            "phone":     _fake.phone_number()[:20],
            "region_id": random.choice(region_ids),
            "credit":    round(random.uniform(0, 1_000_000), 2),
            "avatar":    avatar,
            "remarks":   remarks,
        })


def _update(conn) -> None:
    remarks = _fake.paragraph(nb_sentences=8)
    sql = """
        UPDATE src_schema.customers
        SET remarks = :remarks, updated_at = SYSTIMESTAMP
        WHERE customer_id = (
            SELECT customer_id FROM (
                SELECT customer_id FROM src_schema.customers
                WHERE status = 'ACTIVE'
                ORDER BY DBMS_RANDOM.VALUE
            ) WHERE ROWNUM = 1
        )
    """
    with conn.cursor() as cur:
        cur.execute(sql, {"remarks": remarks})


def _delete(conn) -> None:
    sql = """
        DELETE FROM src_schema.customers
        WHERE customer_id = (
            SELECT customer_id FROM (
                SELECT c.customer_id FROM src_schema.customers c
                WHERE c.status = 'CLOSED'
                  AND NOT EXISTS (
                      SELECT 1 FROM src_schema.orders o
                      WHERE o.customer_id = c.customer_id
                  )
                ORDER BY DBMS_RANDOM.VALUE
            ) WHERE ROWNUM = 1
        )
    """
    with conn.cursor() as cur:
        cur.execute(sql)
