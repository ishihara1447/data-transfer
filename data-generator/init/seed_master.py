"""
seed_master.py: 初期マスタデータ投入（冪等）
REGIONS / PRODUCT_CATEGORIES / PRODUCTS の最低限のマスタを INSERT IGNORE 相当で投入
"""
import oracledb


def seed(conn: oracledb.Connection) -> None:
    _seed_regions(conn)
    _seed_product_categories(conn)
    _seed_products(conn)


def _seed_regions(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM src_schema.regions")
        if cur.fetchone()[0] > 0:
            return

    rows = [
        # (region_code, region_name, parent_code)
        ("JP",     "日本",       None),
        ("JP-KT",  "関東",       "JP"),
        ("JP-KS",  "関西",       "JP"),
        ("JP-CH",  "中部",       "JP"),
        ("JP-KY",  "九州",       "JP"),
        ("JP-TK",  "東京都",     "JP-KT"),
        ("JP-KN",  "神奈川県",   "JP-KT"),
        ("JP-OS",  "大阪府",     "JP-KS"),
        ("JP-KO",  "京都府",     "JP-KS"),
        ("JP-AI",  "愛知県",     "JP-CH"),
    ]
    # parent_code → region_id マップ
    code_to_id: dict = {}

    with conn.cursor() as cur:
        for code, name, parent_code in rows:
            parent_id = code_to_id.get(parent_code)
            cur.execute("""
                INSERT INTO src_schema.regions
                    (region_code, region_name, parent_region_id, is_active)
                VALUES (:code, :name, :pid, 1)
                RETURNING region_id INTO :rid
            """, {
                "code": code, "name": name, "pid": parent_id,
                "rid": cur.var(oracledb.NUMBER),
            })
            rid = int(cur.bindvars["rid"].getvalue()[0])
            code_to_id[code] = rid


def _seed_product_categories(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM src_schema.product_categories")
        if cur.fetchone()[0] > 0:
            return

    rows = [
        ("CAT-ELEC", "電子機器",   None),
        ("CAT-BOOK", "書籍",       None),
        ("CAT-FOOD", "食品",       None),
        ("CAT-PC",   "パソコン",   "CAT-ELEC"),
        ("CAT-SP",   "スマートフォン", "CAT-ELEC"),
        ("CAT-IT",   "IT書籍",     "CAT-BOOK"),
    ]
    code_to_id: dict = {}

    with conn.cursor() as cur:
        for code, name, parent_code in rows:
            parent_id = code_to_id.get(parent_code)
            cur.execute("""
                INSERT INTO src_schema.product_categories
                    (category_code, category_name, parent_category_id,
                     depth_level, is_active)
                VALUES (:code, :name, :pid,
                        CASE WHEN :pid IS NULL THEN 1 ELSE 2 END, 1)
                RETURNING category_id INTO :cid
            """, {
                "code": code, "name": name, "pid": parent_id,
                "cid": cur.var(oracledb.NUMBER),
            })
            cid = int(cur.bindvars["cid"].getvalue()[0])
            code_to_id[code] = cid


def _seed_products(conn) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM src_schema.products")
        if cur.fetchone()[0] > 0:
            return

        cur.execute(
            "SELECT category_id FROM src_schema.product_categories "
            "WHERE parent_category_id IS NOT NULL"
        )
        cat_rows = cur.fetchall()

    if not cat_rows:
        return

    import random
    cat_ids = [r[0] for r in cat_rows]

    products = [
        ("PRD-001", "ノートPC Pro 15",         cat_ids[0 % len(cat_ids)], 198000),
        ("PRD-002", "スマートフォン X12",       cat_ids[1 % len(cat_ids)], 89800),
        ("PRD-003", "Pythonプログラミング入門",  cat_ids[2 % len(cat_ids)], 3200),
        ("PRD-004", "Oracle Database設計",     cat_ids[2 % len(cat_ids)], 4500),
        ("PRD-005", "ワイヤレスイヤホン Pro",   cat_ids[0 % len(cat_ids)], 24800),
        ("PRD-006", "USBハブ 7ポート",         cat_ids[0 % len(cat_ids)], 3980),
        ("PRD-007", "タブレット Air 11",        cat_ids[1 % len(cat_ids)], 68000),
        ("PRD-008", "データベース実践ガイド",    cat_ids[2 % len(cat_ids)], 3800),
        ("PRD-009", "Webカメラ HD",             cat_ids[0 % len(cat_ids)], 8900),
        ("PRD-010", "機械学習の基礎",           cat_ids[2 % len(cat_ids)], 4200),
    ]

    with conn.cursor() as cur:
        for code, name, cat_id, price in products:
            cur.execute("""
                INSERT INTO src_schema.products
                    (product_code, product_name, category_id,
                     unit_price, stock_quantity, is_discontinued)
                VALUES (:code, :name, :cat, :price, :stock, 0)
            """, {
                "code":  code,
                "name":  name,
                "cat":   cat_id,
                "price": price,
                "stock": random.randint(10, 500),
            })
