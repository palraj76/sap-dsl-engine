"""
SAP JSON DSL Engine — Python Caller
Usage:
    python dsl_client.py --host https://sap.client.internal:8000 \
                         --client-id CLIENT_ACME_001 \
                         --secret <secret>
"""

import requests
import time
import json
import uuid
import argparse
import sys

# ─── Token Manager ───────────────────────────────────────────

_token_cache = {}


def get_token(endpoint: str, client_id: str, secret: str) -> str:
    cached = _token_cache.get(client_id)
    if cached and cached["expires_at"] > time.time() + 600:
        return cached["token"]

    resp = requests.post(
        f"{endpoint}/auth",
        json={"client_id": client_id, "client_secret": secret},
        verify=True,
        timeout=10,
    )
    resp.raise_for_status()
    data = resp.json()

    _token_cache[client_id] = {
        "token": data["access_token"],
        "expires_at": time.time() + data["expires_in"],
    }
    return data["access_token"]


def invalidate_token(client_id: str):
    _token_cache.pop(client_id, None)


# ─── Query Executor ──────────────────────────────────────────


def query_sap(endpoint: str, client_id: str, secret: str, payload: dict) -> dict:
    token = get_token(endpoint, client_id, secret)
    request_id = str(uuid.uuid4())

    resp = requests.post(
        f"{endpoint}/query",
        json=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "X-DSL-Client-ID": client_id,
            "X-DSL-Request-ID": request_id,
            "Content-Type": "application/json",
        },
        verify=True,
        timeout=35,
    )

    if resp.status_code == 401:
        invalidate_token(client_id)
        return query_sap(endpoint, client_id, secret, payload)

    result = resp.json()

    if result.get("errors"):
        print(f"[ERROR] DSL errors:")
        for err in result["errors"]:
            print(f"  {err['code']}: {err['message']}")
        return result

    return result


# ─── Query Builders ──────────────────────────────────────────


def build_user_query(user_types: list = None, limit: int = 100) -> dict:
    """Simple query: list users from USR02"""
    if user_types is None:
        user_types = ["A"]

    return {
        "version": "1.3",
        "query_id": f"Q-PY-{uuid.uuid4().hex[:8]}",
        "sources": [{"table": "USR02", "alias": "u"}],
        "select": [
            {"field": "u.BNAME", "alias": "user", "type": "STRING"},
            {"field": "u.USTYP", "alias": "user_type", "type": "STRING"},
            {"field": "u.TRDAT", "alias": "last_login", "type": "DATE"},
        ],
        "filters": {
            "logic": "AND",
            "conditions": [
                {"field": "u.USTYP", "op": "IN", "value": user_types}
            ],
        },
        "order_by": [{"field": "u.BNAME", "direction": "asc"}],
        "limit": {"rows": limit},
    }


def build_user_role_query(as_of_date: str, limit: int = 100) -> dict:
    """JOIN query: users with their roles"""
    return {
        "version": "1.3",
        "query_id": f"Q-PY-{uuid.uuid4().hex[:8]}",
        "sources": [{"table": "USR02", "alias": "u"}],
        "joins": [
            {
                "type": "left",
                "target": {"table": "AGR_USERS", "alias": "ru"},
                "on": {
                    "logic": "AND",
                    "conditions": [
                        {"left": "u.BNAME", "op": "=", "right": "ru.UNAME"},
                        {"left": "u.MANDT", "op": "=", "right": "ru.MANDT"},
                    ],
                },
            }
        ],
        "select": [
            {"field": "u.BNAME", "alias": "user", "type": "STRING"},
            {"field": "ru.AGR_NAME", "alias": "role", "type": "STRING"},
            {"field": "ru.FROM_DAT", "alias": "valid_from", "type": "DATE"},
            {"field": "ru.TO_DAT", "alias": "valid_to", "type": "DATE"},
        ],
        "filters": {
            "logic": "AND",
            "conditions": [
                {"field": "u.USTYP", "op": "=", "value": "A"},
                {"field": "ru.TO_DAT", "op": ">=", "param": "asOfDate"},
            ],
        },
        "params": {"asOfDate": as_of_date},
        "order_by": [{"field": "u.BNAME", "direction": "asc"}],
        "limit": {"rows": limit, "page_size": 50},
    }


def build_entity_query() -> dict:
    """Entity mode query: uses pre-defined user_access entity"""
    return {
        "version": "1.3",
        "query_id": f"Q-PY-{uuid.uuid4().hex[:8]}",
        "entity": "user_access",
        "select": [
            {"alias": "user"},
            {"alias": "role"},
            {"alias": "auth_object"},
        ],
        "filters": {
            "logic": "AND",
            "conditions": [
                {"field": "user_type", "op": "IN", "value": ["A", "B"]}
            ],
        },
        "limit": {"rows": 50},
    }


# ─── Pagination Helper ───────────────────────────────────────


def fetch_all_pages(endpoint: str, client_id: str, secret: str, payload: dict) -> list:
    all_rows = []
    page_token = None

    while True:
        if page_token:
            payload["limit"]["page_token"] = page_token

        result = query_sap(endpoint, client_id, secret, payload)
        if result.get("errors"):
            break

        rows = result.get("data", {}).get("rows", [])
        all_rows.extend(rows)

        meta = result.get("meta", {})
        print(f"  Page: {meta.get('row_count', 0)} rows, "
              f"total so far: {len(all_rows)}, "
              f"has_more: {meta.get('has_more', False)}")

        if not meta.get("has_more", False):
            break

        page_token = meta.get("next_page_token")

    return all_rows


# ─── Main ────────────────────────────────────────────────────


def print_result(result: dict):
    if result.get("errors"):
        return

    meta = result.get("meta", {})
    print(f"\n── Result ──")
    print(f"Query ID:  {result.get('query_id', 'N/A')}")
    print(f"Rows:      {meta.get('row_count', 0)}")
    print(f"Strategy:  {meta.get('strategy_used', 'N/A')}")
    print(f"Exec time: {meta.get('execution_time_ms', 0)}ms")

    if result.get("warnings"):
        print(f"Warnings:")
        for w in result["warnings"]:
            print(f"  {w['code']}: {w['message']}")

    rows = result.get("data", {}).get("rows", [])
    if rows:
        # Print as table
        headers = list(rows[0].keys()) if isinstance(rows[0], dict) else []
        if headers:
            print(f"\n  {'  '.join(h.ljust(20) for h in headers)}")
            print(f"  {'  '.join('-' * 20 for _ in headers)}")
            for row in rows[:20]:  # show first 20
                print(f"  {'  '.join(str(row.get(h, '')).ljust(20) for h in headers)}")
            if len(rows) > 20:
                print(f"  ... and {len(rows) - 20} more rows")


def main():
    parser = argparse.ArgumentParser(description="SAP JSON DSL Engine - Python Caller")
    parser.add_argument("--host", required=True, help="SAP endpoint base URL")
    parser.add_argument("--client-id", required=True, help="DSL client ID")
    parser.add_argument("--secret", required=True, help="Client secret")
    parser.add_argument("--query", choices=["users", "roles", "entity"], default="users")
    parser.add_argument("--limit", type=int, default=10)
    args = parser.parse_args()

    endpoint = args.host.rstrip("/") + "/sap/zdsl"

    print(f"Connecting to: {endpoint}")
    print(f"Client ID: {args.client_id}")
    print(f"Query type: {args.query}")

    if args.query == "users":
        payload = build_user_query(limit=args.limit)
    elif args.query == "roles":
        payload = build_user_role_query(as_of_date="20260324", limit=args.limit)
    elif args.query == "entity":
        payload = build_entity_query()

    print(f"\nPayload:\n{json.dumps(payload, indent=2)}")
    result = query_sap(endpoint, args.client_id, args.secret, payload)
    print_result(result)


if __name__ == "__main__":
    main()
