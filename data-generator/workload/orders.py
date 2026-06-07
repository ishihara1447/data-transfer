"""
orders.py: ORDERS / ORDER_ITEMS / ORDER_STATUS_HISTORY への DML 発行
新規注文INSERT → ステータス遷移UPDATE → キャンセル時DELETE(ORDER_ITEMS先)
"""
import json
import random
import oracledb
from faker import Faker

_fake = Faker("ja_JP")

STATUS_FLOW = ["DRAFT", "CONFIRMED", "SHIPPED", "DELIVERED"]


def _customer_ids(conn) -> list:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT customer_id FROM src_schema.customers "
            "WHERE status = 'ACTIVE' AND ROWNUM <= 500"
        )
        rows = cur.fetchall()
    return [r[0] for r in rows] if rows else []


def _product_ids(conn) -> list:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT product_id, unit_price FROM src_schema.products "
            "WHERE is_discontinued = 0 AND ROWNUM <= 200"
        )
        rows = cur.fetchall()
    return rows if rows else []


def _region_ids(conn) -> list:
    with conn.cursor() as cur:
        cur.execute("SELECT region_id FROM src_schema.regions WHERE is_active = 1")
        rows = cur.fetchall()
    return [r[0] for r in rows] if rows else [None]


def run(conn: oracledb.Connection, cfg: dict) -> None:
    batch = random.randint(cfg["batch_min"], cfg["batch_max"])
    customer_ids = _customer_ids(conn)
    product_ids  = _product_ids(conn)
    region_ids   = _region_ids(conn)

    if not customer_ids:
        return

    for _ in range(batch):
        action = random.choices(["new", "advance", "cancel"], weights=[40, 50, 10])[0]

        if action == "new" and product_ids:
            _new_order(conn, customer_ids, product_ids, region_ids)
        elif action == "advance":
            _advance_status(conn)
        elif action == "cancel":
            _cancel_order(conn)


def _new_order(conn, customer_ids, product_ids, region_ids) -> None:
    cust_id = random.choice(customer_ids)
    region_id = random.choice(region_ids)

    address = json.dumps({
        "postal_code": _fake.postcode(),
        "prefecture":  _fake.prefecture(),
        "city":        _fake.city(),
        "address":     _fake.address(),
    }, ensure_ascii=False)

    order_sql = """
        INSERT INTO src_schema.orders (
            order_no, customer_id, shipping_region_id, status,
            order_date, total_amount, tax_amount, shipping_address
        ) VALUES (
            :order_no, :cust_id, :region_id, 'DRAFT',
            TRUNC(SYSDATE), :total, :tax, :address
        ) RETURNING order_id INTO :oid
    """
    n_items = random.randint(1, 5)
    items = random.sample(product_ids, min(n_items, len(product_ids)))
    total = sum(p[1] for p in items)

    with conn.cursor() as cur:
        oid_var = cur.var(oracledb.NUMBER)
        cur.execute(order_sql, {
            "order_no": f"ORD{random.randint(1000000, 9999999)}",
            "cust_id":  cust_id,
            "region_id":region_id,
            "total":    total,
            "tax":      round(total * 0.1, 2),
            "address":  address,
            "oid":      oid_var,
        })
        order_id = int(oid_var.getvalue()[0])

        for line_no, (pid, price) in enumerate(items, 1):
            qty = random.randint(1, 10)
            cur.execute("""
                INSERT INTO src_schema.order_items (
                    order_id, product_id, line_no, quantity,
                    unit_price, discount_rate, line_amount
                ) VALUES (
                    :oid, :pid, :line, :qty,
                    :price, 0, :qty * :price
                )
            """, {"oid": order_id, "pid": pid, "line": line_no,
                  "qty": qty, "price": price})

        cur.execute("""
            INSERT INTO src_schema.order_status_history
                (order_id, from_status, to_status, changed_by, created_at)
            VALUES (:oid, NULL, 'DRAFT', 'data-generator', SYSTIMESTAMP)
        """, {"oid": order_id})


def _advance_status(conn) -> None:
    for from_st, to_st in zip(STATUS_FLOW[:-1], STATUS_FLOW[1:]):
        with conn.cursor() as cur:
            cur.execute("""
                UPDATE src_schema.orders
                SET status = :to_st, updated_at = SYSTIMESTAMP
                WHERE order_id = (
                    SELECT order_id FROM (
                        SELECT order_id FROM src_schema.orders
                        WHERE status = :from_st
                        ORDER BY DBMS_RANDOM.VALUE
                    ) WHERE ROWNUM = 1
                )
                RETURNING order_id INTO :oid
            """, {"to_st": to_st, "from_st": from_st,
                  "oid": cur.var(oracledb.NUMBER)})

            break


def _cancel_order(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("""
            SELECT order_id FROM (
                SELECT order_id FROM src_schema.orders
                WHERE status = 'DRAFT'
                ORDER BY DBMS_RANDOM.VALUE
            ) WHERE ROWNUM = 1
        """)
        row = cur.fetchone()
        if not row:
            return
        oid = row[0]

        cur.execute("DELETE FROM src_schema.order_items WHERE order_id = :oid",
                    {"oid": oid})
        cur.execute("DELETE FROM src_schema.order_status_history WHERE order_id = :oid",
                    {"oid": oid})
        cur.execute("DELETE FROM src_schema.orders WHERE order_id = :oid",
                    {"oid": oid})
