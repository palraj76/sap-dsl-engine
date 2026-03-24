# SAP JSON Query Engine (DSL) – Functional & Technical Specification

## 1. Vision

A **JSON-driven query and analytics DSL for SAP** that compiles into ABAP Open SQL (or HANA SQL), enabling dynamic data extraction, aggregation, and insight generation without writing custom ABAP per use case.

The engine is a **deliberately dumb executor**. It contains no business logic, no hardcoded table names, and no domain knowledge. Every table name, field, join condition, and filter arrives at runtime inside the JSON payload from the caller. The engine's only job is to parse that JSON safely, validate it against a whitelist, compile it into ABAP SQL, execute it, and return structured results. This is by design — the intelligence lives in the caller's application, not in SAP.

---

## 2. Deployment Context

### 2.1 Who owns what

This engine is built and maintained by a **3rd party service provider** (us). It is deployed into **client SAP systems** that we do not own. The client is a separate organisation whose SAP system sits behind their corporate firewall.

```
┌─────────────────────────────┐        ┌──────────────────────────────┐
│   Our network (3rd party)   │        │   Client network (firewall)  │
│                             │        │                              │
│  ┌─────────────────────┐    │        │  ┌────────────────────────┐  │
│  │  Our application    │    │  HTTPS │  │  SAP system            │  │
│  │  Java/Python/Node   │────┼────────┼─▶│  ZCL_JSON_DSL_ENGINE   │  │
│  │                     │    │  +VPN  │  │  (dumb executor)       │  │
│  │  Business logic     │    │  or IP │  │                        │  │
│  │  Query definitions  │◀───┼────────┼──│  Returns raw data      │  │
│  │  Data processing    │    │ whitelist  │                        │  │
│  └─────────────────────┘    │        │  └────────────────────────┘  │
│                             │        │                              │
│  ← Our IP, never visible →  │        │  ← Client owns this system → │
└─────────────────────────────┘        └──────────────────────────────┘
```

### 2.2 IP separation — the core design principle

| Layer | Location | Owned by | Visible to competitor? |
|-------|----------|----------|----------------------|
| Which tables to query | Our application | Us | No — never leaves our network |
| Which fields to select | Our application | Us | No — never leaves our network |
| WHERE conditions / business rules | Our application | Us | No — never leaves our network |
| How to process returned data | Our application | Us | No — never leaves our network |
| Query execution engine | Client SAP | Us (installed) | Yes — but it is intentionally generic |
| SAP database | Client SAP | Client | N/A |

A competitor who obtains the ABAP engine transport gets a generic, table-agnostic query executor with no domain knowledge embedded in it. They cannot determine what we query, why, or what we do with the results. The engine is not our competitive advantage — our intelligence layer is.

### 2.3 Network access model

- Access is **pull-only**: we initiate all calls, SAP never calls out to us
- The client grants us access via one of two mechanisms:
  - **VPN tunnel** — our service IP connects through a dedicated VPN into the client network
  - **IP whitelist** — the client's firewall allows inbound HTTPS from our static service IP(s) to the SAP ICF port
- All traffic is HTTPS (TLS 1.2+). Plaintext HTTP is not permitted
- Authentication uses a short-lived bearer token issued per session (see §20 — HTTP API Contract)
- The DSL JSON payload travels inside the encrypted HTTPS body — never in URL parameters

### 2.4 Multi-client deployment model

**One transport, many clients.** The ABAP transport (`ZDL_JSON_DSL`) is identical for every client. It is installed once into each client's SAP system by their BASIS team. There is no client-specific ABAP code. All per-client customisation (whitelist, guardrails, credentials) is done via SM30 table entries after installation.

**One endpoint path, different hosts.** Every client installation registers the same ICF path — `/sap/zdsl/query`. What differs per client is the SAP host (their server, their network). From our application's perspective, each client has a unique URL:

```
Client A:  https://sap.clienta.internal:8000/sap/zdsl/query
Client B:  https://erp.clientb.corp:44300/sap/zdsl/query
Client C:  https://s4h.clientc.net:8443/sap/zdsl/query
          └──── different host ────┘  └──── same path ────┘
```

The SAP system does not need to know which client number or application instance is calling. Client identity lives in our application registry, not in SAP.

**How our application distinguishes clients:**

Our application maintains a client registry keyed by a unique client identifier (e.g. installation number + SID, or a UUID we assign at onboarding). Each entry holds the client's SAP endpoint URL and credential reference. Every outbound call includes an `X-DSL-Client-ID` header which we use for correlation logging on our side — SAP ignores this header, it is purely for our tracing.

```json
{
  "client_id": "CLIENT_ACME_001",
  "sap_sid": "PRD",
  "sap_installation_number": "0020123456",
  "sap_endpoint": "https://sap.acme.internal:8000/sap/zdsl",
  "client_secret_ref": "vault://sap-dsl/acme/client_secret",
  "active": true
}
```

**Response handling:** SAP returns raw JSON. Our Java application receives it directly and processes it in the application pipeline. No transformation layer is needed between SAP and our application.

**Client isolation:** Each client's SAP has its own `ZJSON_DSL_WL` whitelist, its own `ZJSON_DSL_CONFIG` guardrails, and its own `ZJSON_DSL_CLIENTS` credentials table. Installations are fully isolated — a misconfiguration at one client cannot affect another.

---

## 3. Scope Definition

### ✅ Must Support (Phase 1–2)
- Multi-table SELECT with alias-qualified fields
- JOINs (INNER, LEFT) with multi-condition AND/OR logic including MANDT
- WHERE conditions with logical grouping (AND/OR/nested expression trees)
- Aggregations (COUNT, SUM, DISTINCT)
- GROUP BY with strict enforcement: non-aggregate selects must appear in GROUP BY
- Row limits with offset-based pagination (AMDP recommended for large datasets)
- ORDER BY mandatory when pagination is active
- Field type annotations (STRING, DATE, AMOUNT, CURRENCY, QUANTITY, UNIT, NUMBER, BOOLEAN, TIMESTAMP)
- Caller authentication via bearer token (mapped to SAP technical service user)
- HTTP API contract for external callers — Java, Python, Node, or any HTTP client
- Semantic entity resolution (logical name → physical tables + joins) — engine-side convenience, not caller-side intelligence

### ⚠️ Conditional (Phase 3)

Each item below includes a strawman JSON syntax to prevent scope ambiguity at the Phase 2/3 boundary.

**Derived fields (expressions)**
```json
"derived": [
  { "alias": "full_name", "expr": { "fn": "CONCAT", "args": ["u.FNAME", "u.LNAME"] } }
]
```

**Subqueries — full DSL recursion**

Subqueries reuse the full DSL structure for consistency:
```json
"filters": {
  "logic": "AND",
  "conditions": [
    {
      "field": "u.BNAME",
      "op": "IN",
      "subquery": {
        "sources": [{ "table": "AGR_USERS", "alias": "su" }],
        "select": [{ "field": "su.UNAME", "alias": "uname", "type": "STRING" }],
        "filters": {
          "logic": "AND",
          "conditions": [
            { "field": "su.AGR_NAME", "op": "=", "value": "Z_ADMIN" }
          ]
        }
      }
    }
  ]
}
```

**Calculated metrics**
```json
"metrics": [
  { "type": "calc", "expr": "SUM(amount) / COUNT(*)", "alias": "avg_amount" }
]
```

**HAVING clause** — already in Phase 1–2 DSL structure; dynamic generation is the Phase 3 complexity (see §8).

### ❌ Not Supported (Initial Phase)
- Arbitrary SQL functions
- Window functions
- Deep nested subqueries (beyond one level)
- Cross-database joins
- Dynamic schema discovery at runtime

---

## 3. JSON DSL Structure (v1.2)

Two query modes are supported. In **entity mode** the caller uses a logical name; in **raw mode** the caller supplies `sources` and `joins` directly. The engine detects the mode from the presence of the `entity` key.

```json
{
  "version": "1.3",

  "entity": "user_access",

  "sources": [],
  "joins": [],
  "select": [],
  "filters": {},
  "group_by": [],
  "metrics": [],
  "having": [],
  "order_by": [],
  "limit": {},

  "params": {},
  "output": {}
}
```

> `entity` and `sources`/`joins` are mutually exclusive. The validator raises `DSL_PARSE_005` if both are present.

---

## 4. Semantic Entity Layer

### 4.1 Purpose

The semantic layer lets callers refer to business concepts instead of SAP table names. The entity registry maps each logical name to its physical tables, pre-wired joins, and canonical field aliases. This isolates consumers from SAP data model changes and ensures MANDT and other mandatory join conditions are always applied correctly.

```
Caller uses:  { "entity": "user_access" }
Engine resolves to:
  sources: USR02 (alias u)
  joins:   AGR_USERS (alias ru) ON u.BNAME = ru.UNAME AND u.MANDT = ru.MANDT
           AGR_1251  (alias auth) ON ru.AGR_NAME = auth.ROLE AND ru.MANDT = auth.MANDT
  fields:  user → u.BNAME, role → ru.AGR_NAME, auth_object → auth.OBJECT, ...
```

### 4.2 Entity Registry Schema

Entities are defined in a configuration table `ZJSON_DSL_ENTITY` or a JSON config file `ZJSON_DSL_ENTITIES.json`:

```json
{
  "version": "1.0",
  "entities": [
    {
      "name": "user_access",
      "description": "User master with role and authorization object assignments",
      "sources": [
        { "table": "USR02", "alias": "u" }
      ],
      "joins": [
        {
          "type": "left",
          "target": { "table": "AGR_USERS", "alias": "ru" },
          "on": {
            "logic": "AND",
            "conditions": [
              { "left": "u.BNAME",  "op": "=", "right": "ru.UNAME" },
              { "left": "u.MANDT",  "op": "=", "right": "ru.MANDT" }
            ]
          }
        },
        {
          "type": "left",
          "target": { "table": "AGR_1251", "alias": "auth" },
          "on": {
            "logic": "AND",
            "conditions": [
              { "left": "ru.AGR_NAME", "op": "=", "right": "auth.ROLE"  },
              { "left": "ru.MANDT",    "op": "=", "right": "auth.MANDT" }
            ]
          }
        }
      ],
      "fields": [
        { "alias": "user",        "field": "u.BNAME",      "type": "STRING" },
        { "alias": "user_type",   "field": "u.USTYP",      "type": "STRING" },
        { "alias": "role",        "field": "ru.AGR_NAME",  "type": "STRING" },
        { "alias": "valid_from",  "field": "ru.FROM_DAT",  "type": "DATE"   },
        { "alias": "valid_to",    "field": "ru.TO_DAT",    "type": "DATE"   },
        { "alias": "auth_object", "field": "auth.OBJECT",  "type": "STRING" }
      ]
    }
  ]
}
```

### 4.3 Entity Mode Query Example

In entity mode, `select` entries reference the entity's canonical `alias` names rather than raw `table.FIELD` paths. The builder resolves them to physical fields before SQL generation.

```json
{
  "version": "1.2",
  "query_id": "Q-20260123-0010",
  "entity": "user_access",

  "select": [
    { "alias": "user" },
    { "alias": "role" },
    { "alias": "auth_object" }
  ],

  "filters": {
    "logic": "AND",
    "conditions": [
      { "field": "user_type", "op": "IN",  "value": ["A", "B"] },
      { "field": "valid_from", "op": "<=", "param": "asOfDate"  },
      { "field": "valid_to",   "op": ">=", "param": "asOfDate"  }
    ]
  },

  "params": { "asOfDate": "20260123" },
  "order_by": [{ "field": "user", "direction": "asc" }],
  "limit": { "rows": 200, "page_size": 50 }
}
```

---

## 5. Section-wise Specification

### 5.1 Sources

Used in raw mode only. Raises `DSL_PARSE_005` if present alongside `entity`.

```json
"sources": [
  { "table": "USR02", "alias": "u" }
]
```

**Rules:**
- First source is the base table
- Alias is mandatory
- Table must be present in the whitelist configuration (see §9.1)

---

### 5.2 Joins

The `on` block uses a **structured condition tree** supporting AND/OR logic. The flat array syntax from v1.0/v1.1 is deprecated (warning `DSL_DEPR_002`) and will be removed in v2.0.

**MANDT must always be included** in join conditions for cross-client-safe queries. The validator raises `DSL_SEM_007` if a join between two client-dependent tables omits MANDT.

```json
"joins": [
  {
    "type": "left",
    "target": { "table": "AGR_USERS", "alias": "ru" },
    "on": {
      "logic": "AND",
      "conditions": [
        { "left": "u.BNAME", "op": "=", "right": "ru.UNAME" },
        { "left": "u.MANDT", "op": "=", "right": "ru.MANDT" }
      ]
    }
  }
]
```

**`on` condition tree schema:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `logic` | enum | **Yes** | `AND` or `OR` — how conditions in this node are combined. Must be explicit; no default assumed |
| `conditions` | array | **Yes** | Mix of leaf conditions `{ left, op, right }` and nested condition trees |

> The `logic` field is **mandatory** in every condition node, both in `on` blocks and in `filters`. Omitting it raises `DSL_PARSE_006`. There is no implicit default — an ambiguous join is a broken query in SAP.

**Nested OR example** (join on one of two possible key fields):
```json
"on": {
  "logic": "AND",
  "conditions": [
    { "left": "u.MANDT", "op": "=", "right": "ru.MANDT" },
    {
      "logic": "OR",
      "conditions": [
        { "left": "u.BNAME", "op": "=", "right": "ru.UNAME" },
        { "left": "u.BNAME", "op": "=", "right": "ru.BNAME" }
      ]
    }
  ]
}
```

**Rules:**
- Avoid raw SQL strings in any condition field
- Both tables in any condition must be whitelisted
- MANDT condition is mandatory for client-dependent table joins

---

### 5.3 Select

Fields carry an optional `type` annotation to drive type-safe ABAP variable declarations. When omitted, the engine defaults to `STRING` and emits warning `DSL_SEM_006`.

```json
"select": [
  { "field": "u.BNAME",       "alias": "user",       "type": "STRING"                              },
  { "field": "ru.AGR_NAME",   "alias": "role",        "type": "STRING"                              },
  { "field": "ru.FROM_DAT",   "alias": "valid_from",  "type": "DATE"                                },
  { "field": "doc.NET_VALUE", "alias": "net_value",   "type": "AMOUNT",   "currency_field": "doc.WAERS" },
  { "field": "doc.QTY",       "alias": "quantity",    "type": "QUANTITY", "unit_field":     "doc.MEINS" }
]
```

**Supported field types and ABAP mappings:**

| DSL Type    | ABAP Type    | Notes |
|-------------|--------------|-------|
| `STRING`    | `C` / `CHAR` | Default when type is omitted |
| `DATE`      | `D`          | Binds as SAP date format `YYYYMMDD` |
| `AMOUNT`    | `P` (CURR)   | Requires `currency_field` pointing to the companion WAERS/CUKY field |
| `CURRENCY`  | `CUKY`       | 5-char ISO currency key field itself (e.g. `doc.WAERS`) |
| `QUANTITY`  | `P` (QUAN)   | Requires `unit_field` pointing to the companion MEINS/UNIT field |
| `UNIT`      | `UNIT`       | 3-char unit of measure field itself (e.g. `doc.MEINS`) |
| `NUMBER`    | `I` / `N`    | Integer or numeric string |
| `BOOLEAN`   | `C(1)`       | Stored as `X` / ` ` (space) in SAP |
| `TIMESTAMP` | `DEC(15)`    | UTC timestamp; milliseconds |

**AMOUNT and QUANTITY rules:**
- `currency_field` / `unit_field` must point to a field within the same `sources` / `joins` scope
- The referenced companion field must also appear in `select` for the output to carry the currency or unit
- Violation raises `DSL_SEM_008`

**Metric / Select separation — strictly enforced:**
- Fields in `select` must be non-aggregate
- Aggregate expressions must only appear in `metrics`
- Every non-aggregate `select` field must appear in `group_by` when `metrics` is non-empty
- Violation raises `DSL_SEM_003`

**Field qualification — strictly enforced:**

Every `field` reference anywhere in the DSL (`select`, `filters`, `group_by`, `order_by`, join `left`/`right`) **must** be qualified as `alias.FIELDNAME`. Bare field names without a table alias are rejected with `DSL_SEM_011`.

```json
✅ Accepted:  { "field": "u.BNAME" }
❌ Rejected:  { "field": "BNAME" }
❌ Rejected:  { "field": "USR02.BNAME" }   ← use alias, not table name
```

Rationale: unqualified field names are ambiguous when multiple joined tables share a column name (e.g. `MANDT`, `ERDAT`, `ERNAM` appear in dozens of SAP tables). Requiring alias qualification eliminates ambiguous SQL and surfaces join errors at validation time rather than at runtime.

---

### 5.4 Filters (WHERE)

Filters are a **condition tree** (not a flat array), enabling full AND/OR/nested grouping. This is the engine's expression tree (AST) for WHERE clause generation.

```json
"filters": {
  "logic": "AND",
  "conditions": [
    { "field": "u.USTYP", "op": "IN", "value": ["A", "B"] },
    { "field": "ru.FROM_DAT", "op": "<=", "param": "asOfDate" },
    { "field": "ru.TO_DAT",   "op": ">=", "param": "asOfDate" },
    {
      "logic": "OR",
      "conditions": [
        { "field": "u.CLASS", "op": "=", "value": "X" },
        { "field": "u.CLASS", "op": "=", "value": "Y" }
      ]
    }
  ]
}
```

Generated SQL:
```sql
WHERE u.USTYP IN ('A','B')
  AND ru.FROM_DAT <= :asOfDate
  AND ru.TO_DAT   >= :asOfDate
  AND ( u.CLASS = 'X' OR u.CLASS = 'Y' )
```

**Condition tree schema:**

| Field | Type | Description |
|-------|------|-------------|
| `logic` | enum | `AND` or `OR` at this node |
| `conditions` | array | Mix of leaf conditions and nested condition trees |

**Leaf condition fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `field` | Yes | Table-aliased field, e.g. `u.USTYP` |
| `op` | Yes | Operator from the allowed set |
| `value` | One of | Literal value or array (for IN / NOT IN) |
| `param` | One of | Key from `params` block; bound at execution time |

**Supported operators:** `=`, `!=`, `>`, `<`, `>=`, `<=`, `IN`, `NOT IN`, `IS NULL`, `IS NOT NULL`, `BETWEEN`

**NULL handling rules:**

`IS NULL` and `IS NOT NULL` are unary operators — they test the field itself, not a comparison value. The `value` and `param` fields must be absent when these operators are used. The validator raises `DSL_SEM_010` if `value` or `param` is present alongside `IS NULL` / `IS NOT NULL`.

```json
{ "field": "auth.OBJECT", "op": "IS NULL" }
{ "field": "ru.TO_DAT",   "op": "IS NOT NULL" }
```

**SAP-specific NULL behaviour the SQL builder must handle:**

| Scenario | SAP Reality | Builder Action |
|----------|-------------|----------------|
| `IS NULL` on a `NOT NULL` DB column | Most SAP tables define all columns as `NOT NULL` with initial values (`' '`, `'00000000'`, `0`). A true SQL NULL is rare | Emit the SQL NULL check as written; the developer is responsible for knowing whether the column can be NULL |
| Initial value vs NULL | SAP stores empty strings as `' '` (space), not NULL. `IS NULL` will not match a space-padded field | Add a hint in `DSL_EXEC_006` warning if an initial-value-type field (STRING/DATE) is used with `IS NULL` |
| `IS NULL` in a JOIN condition | Valid syntax but unusual in SAP joins | Permitted; no special restriction |

> ⚠️ In SAP, using `IS NULL` on character fields rarely produces the expected result. The initial value `' '` is not NULL. Consider using `= ' '` (space) or `= '00000000'` for date fields instead.

> **Backward compatibility:** v1.0/v1.1 flat filter arrays are accepted in v1.2 and treated as an implicit top-level `AND` node. Deprecation warning `DSL_DEPR_001` is emitted. Support removed in v2.0.

---

### 5.5 Group By

```json
"group_by": ["u.BNAME"]
```

The validator strictly enforces: every field in `select` that is not a metric alias must appear in `group_by` when `metrics` is non-empty. Violation raises `DSL_SEM_003`.

---

### 5.6 Metrics

> **COUNT DISTINCT version gate:** `count_distinct` requires NetWeaver 7.40 SP08+ (ABAP release 740). On older systems, the engine falls back to: `SELECT COUNT(*) FROM ( SELECT DISTINCT field FROM table )`. The engine checks `sy-saprl` at startup and emits warning `DSL_EXEC_003` when the fallback is active.

```json
"metrics": [
  { "type": "count",          "field": "*",           "alias": "row_count"  },
  { "type": "count_distinct", "field": "ru.AGR_NAME", "alias": "role_count" }
]
```

**Supported metrics:** `count`, `count_distinct` *(NW 7.40 SP08+ required)*, `sum`, `avg`, `min`, `max`

---

### 5.7 Having

```json
"having": [
  { "metric": "role_count", "op": ">", "value": 5 }
]
```

**Rules:**
- `metric` must reference an alias defined in the `metrics` array
- Operators follow the same allowed set as filters
- Validator raises `DSL_SEM_002` if `group_by` is absent when `having` is present

---

### 5.8 Order By

```json
"order_by": [
  { "field": "role_count", "direction": "desc" }
]
```

> **Pagination requirement:** `order_by` is **mandatory** when `limit.offset > 0` or `limit.page_token` is non-null. Without a deterministic sort order, paginated results will produce duplicates or missing rows across pages. The validator raises `DSL_SEM_009` if this rule is violated.

---

### 5.9 Limit, Pagination, and Performance Guardrails

```json
"limit": {
  "rows": 200,
  "offset": 0,
  "page_size": 50,
  "page_token": null
}
```

**Field definitions:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `rows` | integer | Yes | Rows requested by the caller. Cannot exceed `max_allowed` system cap |
| `offset` | integer | No | Skip this many rows before returning (default: 0) |
| `page_size` | integer | No | Rows per page; defaults to `rows` if omitted |
| `page_token` | string | No | Opaque token from previous response `meta.next_page_token`; overrides `offset` when present |

**System-level performance guardrails** are configured in `ZJSON_DSL_CONFIG` (custom table, maintained via SM30). They apply to all queries regardless of what the caller requests:

| Config Key | Default | Description |
|------------|---------|-------------|
| `MAX_ROWS_ALLOWED` | `10000` | Hard cap on `limit.rows`. Any request exceeding this is rejected with `DSL_GUARD_001` before execution |
| `MAX_TIMEOUT_SEC` | `30` | Maximum wall-clock seconds for SQL execution. Exceeded queries are killed and return `DSL_EXEC_002` |
| `WARN_ROWS_THRESHOLD` | `5000` | Rows above this threshold emit warning `DSL_GUARD_002` (large result set) |
| `WARN_JOINS_THRESHOLD` | `3` | Queries with more than this many joins emit warning `DSL_GUARD_003` |
| `OFFSET_LARGE_TABLE_ROWS` | `100000` | Estimated table size above which `DSL_EXEC_005` is emitted for offset pagination in Open SQL mode |

**Guardrail enforcement in the DSL:**

```json
"limit": {
  "rows": 15000
}
```

If `MAX_ROWS_ALLOWED` is `10000`, the above is rejected immediately with:

```json
{
  "code": "DSL_GUARD_001",
  "severity": "ERROR",
  "message": "Requested rows (15000) exceeds system maximum (10000)",
  "hint": "Reduce limit.rows or use pagination with page_size ≤ 10000"
}
```

The caller cannot override guardrails. Only a caller with `ZDSL_ADMIN` role can request a temporary config override — and it is logged to `ZJSON_DSL_AUDIT`.

> ⚠️ **Offset pagination performance warning:** Offset pagination in Open SQL mode is implemented via client-side row skipping. **Not recommended for tables exceeding `OFFSET_LARGE_TABLE_ROWS`** — the engine fetches all rows up to `offset + page_size` and discards the skipped portion. For large datasets, use AMDP mode (Option 3) with native `LIMIT n OFFSET m`.

> **ORDER BY is mandatory when pagination is active** (see §5.8).

---

### 5.10 Params

```json
"params": {
  "asOfDate": "20260123"
}
```

Params are bound to filter conditions that use `"param": "<key>"`. The engine applies type-coercion based on the target field's `type` annotation before binding.

---

### 5.11 Output Control

```json
"output": {
  "include_rows": true,
  "include_aggregates": true,
  "include_summary": false
}
```

---

## 6. Mapping to ABAP Open SQL

| JSON Component | ABAP Equivalent | Notes |
|----------------|-----------------|-------|
| `entity` | Resolved to `FROM` + `JOIN` | Entity registry lookup at parse time |
| `sources` | `FROM` clause | Raw mode; alias mandatory |
| `joins` | `JOIN` clause | INNER/LEFT only in Safe Mode; condition tree → SQL string |
| `select` | `SELECT` fields | Type annotation drives ABAP variable declaration |
| `filters` | `WHERE` clause | Condition tree compiled to parameterized string |
| `group_by` | `GROUP BY` | Must align with non-aggregate `select` fields |
| `metrics` | Aggregation functions | `COUNT(*)`, `SUM()`, etc. |
| `having` | `HAVING` | Generated after GROUP BY |
| `limit.rows` | `UP TO n ROWS` | Combined with client-side offset for pagination |
| `order_by` | `ORDER BY` | Required when pagination is active |

---

## 7. Doable vs Not Doable

### ✅ Fully Doable
- Dynamic SELECT list with type-safe binding and currency/quantity companions
- Dynamic WHERE clause with AND/OR condition trees
- JOINs with multi-condition AND/OR including MANDT
- Aggregations
- GROUP BY with strict enforcement
- Row limiting and offset pagination (AMDP recommended for large datasets)
- Semantic entity resolution

### ⚠️ Partially Doable

**Dynamic JOIN conditions**
- AND/OR supported; deeply nested conditions require careful string assembly

**Expressions in SELECT**
- Limited CASE/derived logic; Phase 3 expression engine required for full support

**HAVING clause**
- Supported but complex to generate dynamically; engine must validate GROUP BY presence

**COUNT DISTINCT**
- Requires NetWeaver 7.40 SP08+; fallback pattern available (§5.6)

**Offset pagination**
- Client-side on Open SQL; native on AMDP only

### ❌ Not Doable (Without HANA / Native SQL)
- Window functions (ROW_NUMBER, RANK)
- Recursive queries
- CTEs (WITH clause)
- Complex subqueries beyond one level in SELECT
- JSON processing inside SQL

---

## 8. Execution Strategy Options

The engine evaluates the query feature set and system landscape in order, escalating to the next strategy tier when any trigger condition is met. The first matching tier wins.

### 8.1 Decision Table

| Priority | Condition | Strategy | Reason |
|----------|-----------|----------|--------|
| 1 | Any `derived` field with raw SQL expression present | **Option 3: AMDP** | Raw SQL requires HANA-native execution |
| 2 | `metrics.type = "calc"` (Phase 3 calculated metric) | **Option 3: AMDP** | Arbitrary expressions not safe in Open SQL |
| 3 | Phase 3 subquery with nested `joins` | **Option 3: AMDP** | Complex subquery not expressible in Open SQL |
| 4 | `limit.offset > 0` AND system release < 7.40 SP08 | **Option 2: Native SQL** | No native OFFSET in Open SQL on older releases |
| 5 | `derived` field with simple CONCAT/CASE (no raw SQL) | **Option 2: Native SQL** | Limited derived expression support in Open SQL |
| 6 | Heavy aggregation: `metrics` count ≥ 3 AND `group_by` on 2+ fields AND estimated rows > 500k | **Option 3: AMDP** | HANA columnar engine significantly outperforms ABAP row-by-row for this profile |
| 7 | All other queries | **Option 1: Open SQL** | Default safe path |

> **How the engine checks row estimates:** The executor checks `mandt_count` from `T000` and uses table statistics from `DB02` (if available) or falls back to a whitelist-configured `estimated_rows` hint per table entry. If no estimate is available, Option 1 is used and `DSL_EXEC_005` warns when pagination is active.

### 8.2 Strategy Profiles

| Strategy | ABAP Class Used | SAP Release Required | Risk |
|----------|-----------------|----------------------|------|
| **Option 1: ABAP Open SQL** | `ZCL_JSON_DSL_BUILDER` → Open SQL | Any (ECC 6.0+) | Low |
| **Option 2: Native SQL (EXEC SQL)** | `ZCL_JSON_DSL_BUILDER` → `EXEC SQL` | Any; DB-dependent syntax | Medium — test on target DB |
| **Option 3: AMDP** | `ZCL_JSON_DSL_AMDP_BUILDER` | NW 7.40 SP08+ on HANA | Low overhead; HANA only |

**Option 3 (AMDP) is the recommended target** for production S/4HANA deployments.

---

## 9. Validation Layer

Validation runs in three phases. Any failure in Phase A aborts immediately.

### 9.1 Whitelist Configuration

Defined in `ZJSON_DSL_WHITELIST.json` or custom table `ZJSON_DSL_WL`. Note `MANDT` is explicitly included in all allowed field lists.

> **External caller note:** The HTTP caller is not a SAP dialogue user. All requests arrive via the ICF handler authenticated as a **technical service user** `ZDSL_SVC_USER`, which the client's BASIS team creates during installation. This user holds `ZDSL_AUDIT` role. Whitelist role checks run against this service user's authorizations. The calling application (Java, Python, Node) authenticates to SAP using a bearer token that maps to this service user — it never sends SAP credentials directly. See §20 (HTTP API Contract) and the Client Installation Guide for the full auth flow.

```json
{
  "version": "1.0",
  "entries": [
    {
      "table": "USR02",
      "allowed_fields": ["BNAME", "USTYP", "GLTGV", "GLTGB", "TRDAT", "MANDT"],
      "roles": ["ZDSL_AUDIT", "ZDSL_ADMIN"],
      "description": "User master – login and type data"
    },
    {
      "table": "AGR_USERS",
      "allowed_fields": ["UNAME", "AGR_NAME", "FROM_DAT", "TO_DAT", "MANDT"],
      "roles": ["ZDSL_AUDIT", "ZDSL_ADMIN"],
      "description": "Role assignment header"
    },
    {
      "table": "AGR_1251",
      "allowed_fields": ["ROLE", "OBJECT", "AUTH", "FIELD", "LFROM", "LTO", "MANDT"],
      "roles": ["ZDSL_ADMIN"],
      "description": "Authorization object values – restricted to admin role"
    }
  ]
}
```

**Whitelist rules:**
- Unlisted table → `DSL_WL_TABLE_001`
- Unlisted field → `DSL_WL_FIELD_002`
- Caller lacks required role → `DSL_WL_ROLE_003`
- Authorization object `Z_DSL_EXEC` with `ACTVT = 16` checked at runtime
- Whitelist changes require transport; no direct production edits

### 9.2 Phase A — Structural Validation (pre-parse)
- JSON is well-formed and `version` matches a supported version
- Mandatory fields (`sources` or `entity`, `select`) are present and non-empty
- `entity` and `sources`/`joins` are not both present (`DSL_PARSE_005`)
- No unknown top-level keys (strict schema mode)

### 9.3 Phase B — Semantic Validation (post-parse)
- All tables in `sources` and `joins` exist in the whitelist
- All fields in `select`, filters, `group_by`, `order_by` exist in the whitelist for their table
- All filter condition tree field references are resolvable to a whitelisted alias
- All `having` metric references match an alias in `metrics`; no circular references (a metric alias may not reference itself or another metric alias in a chain)
- `group_by` contains all non-aggregate `select` fields when `metrics` is non-empty (`DSL_SEM_003`)
- `having` is only present when `group_by` is non-empty (`DSL_SEM_002`)
- `params` supplies a value for every `"param": "<key>"` reference in filters (`DSL_SEM_004`)
- `type` annotations are from the allowed set; unknown types default to `STRING` + warning `DSL_SEM_006`
- `currency_field` / `unit_field` references resolve to a field in scope (`DSL_SEM_008`)
- JOIN conditions on client-dependent tables include MANDT (`DSL_SEM_007`)
- `order_by` is present when `limit.offset > 0` or `limit.page_token` is non-null (`DSL_SEM_009`)
- `IS NULL` / `IS NOT NULL` conditions do not carry a `value` or `param` (`DSL_SEM_010`)
- Every `field` reference is qualified as `alias.FIELDNAME` — bare names rejected (`DSL_SEM_011`)

### 9.4 Phase C — Injection Defense
- No raw SQL fragments in any string field
- Field values match `^[A-Z][A-Z0-9_]*\.[A-Z][A-Z0-9_]*$` (enforces `alias.FIELD` pattern; rejects bare names and table-name qualifications)
- Alias values (in `select`, `metrics`) match `^[A-Z][A-Z0-9_]*$` (no dot, no space)
- `value` arrays in filter conditions are scalar only — no nested objects
- Operator values matched against the exact allowed set; any unlisted operator rejected (`DSL_SEC_003`)
- String values exceeding 500 characters in filters rejected (`DSL_SEC_004`)

---

## 10. Error Taxonomy

### 10.1 Error Object Schema

```json
{
  "code": "DSL_PARSE_001",
  "severity": "ERROR",
  "message": "JSON is malformed at line 14, column 8",
  "field": null,
  "table": null,
  "hint": "Check for a missing comma or unmatched brace"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `code` | string | `DSL_<CATEGORY>_<NNN>` |
| `severity` | enum | `ERROR` (aborts) or `WARNING` (continues) |
| `message` | string | Human-readable description |
| `field` | string \| null | DSL path where error occurred, e.g. `select[1].field` |
| `table` | string \| null | SAP table name involved, if applicable |
| `hint` | string \| null | Suggested remediation |

### 10.2 Error Code Reference

**Parse errors (DSL_PARSE_xxx)**

| Code | Severity | Condition |
|------|----------|-----------|
| `DSL_PARSE_001` | ERROR | Malformed JSON |
| `DSL_PARSE_002` | ERROR | Unsupported DSL version |
| `DSL_PARSE_003` | ERROR | Missing mandatory field |
| `DSL_PARSE_004` | ERROR | Unknown top-level key (strict mode) |
| `DSL_PARSE_005` | ERROR | Both `entity` and `sources`/`joins` present |
| `DSL_PARSE_006` | ERROR | Condition node missing mandatory `logic` field |

**Whitelist errors (DSL_WL_xxx)**

| Code | Severity | Condition |
|------|----------|-----------|
| `DSL_WL_TABLE_001` | ERROR | Table not in whitelist |
| `DSL_WL_FIELD_002` | ERROR | Field not allowed for this table |
| `DSL_WL_ROLE_003` | ERROR | Caller lacks required role |

**Semantic errors (DSL_SEM_xxx)**

| Code | Severity | Condition |
|------|----------|-----------|
| `DSL_SEM_001` | ERROR | `having` alias not found in `metrics` |
| `DSL_SEM_002` | ERROR | `having` present without `group_by` |
| `DSL_SEM_003` | ERROR | Non-aggregate `select` field missing from `group_by` |
| `DSL_SEM_004` | ERROR | `param` key in filters not supplied in `params` |
| `DSL_SEM_005` | ERROR | Duplicate alias in `select` or `metrics` |
| `DSL_SEM_006` | WARNING | Unknown `type` annotation — defaulted to `STRING` |
| `DSL_SEM_007` | ERROR | JOIN between client-dependent tables missing MANDT condition |
| `DSL_SEM_008` | ERROR | `currency_field` or `unit_field` not resolvable in scope |
| `DSL_SEM_009` | ERROR | Pagination active but `order_by` is absent |
| `DSL_SEM_010` | ERROR | `IS NULL` / `IS NOT NULL` condition carries a `value` or `param` (must be absent) |
| `DSL_SEM_011` | ERROR | Field reference is not qualified as `alias.FIELDNAME` |

**Injection / security errors (DSL_SEC_xxx)**

| Code | Severity | Condition |
|------|----------|-----------|
| `DSL_SEC_001` | ERROR | Raw SQL fragment detected |
| `DSL_SEC_002` | ERROR | Field or alias contains disallowed characters or fails `alias.FIELD` pattern |
| `DSL_SEC_003` | ERROR | Operator not in allowed set |
| `DSL_SEC_004` | ERROR | Filter value string exceeds 500 characters |

**Performance guardrail errors (DSL_GUARD_xxx)**

| Code | Severity | Condition |
|------|----------|-----------|
| `DSL_GUARD_001` | ERROR | `limit.rows` exceeds `MAX_ROWS_ALLOWED` system cap |
| `DSL_GUARD_002` | WARNING | Result set likely large — `limit.rows` exceeds `WARN_ROWS_THRESHOLD` |
| `DSL_GUARD_003` | WARNING | Query has more joins than `WARN_JOINS_THRESHOLD`; review for performance |

**Execution errors (DSL_EXEC_xxx)**

| Code | Severity | Condition |
|------|----------|-----------|
| `DSL_EXEC_001` | ERROR | ABAP runtime exception during SQL execution |
| `DSL_EXEC_002` | ERROR | Query exceeded `MAX_TIMEOUT_SEC` execution time limit |
| `DSL_EXEC_003` | WARNING | `count_distinct` fallback activated (system below NW 7.40 SP08) |
| `DSL_EXEC_004` | WARNING | Result set truncated at `limit.rows` cap |
| `DSL_EXEC_005` | WARNING | Offset pagination used in Open SQL mode on large table (estimated rows > `OFFSET_LARGE_TABLE_ROWS`) |
| `DSL_EXEC_006` | WARNING | `IS NULL` used on a STRING or DATE field — SAP initial value is `' '` / `'00000000'`, not NULL; result may be empty |

**Deprecation warnings (DSL_DEPR_xxx)**

| Code | Severity | Condition |
|------|----------|-----------|
| `DSL_DEPR_001` | WARNING | Flat filter array used (v1.0/v1.1 syntax); treated as top-level AND. Removed in v2.0 |
| `DSL_DEPR_002` | WARNING | Flat `on` array used in join (v1.0/v1.1 syntax); treated as AND. Removed in v2.0 |

---

## 11. Output Schema

### 11.1 Full Response Schema

```json
{
  "query_id": "Q-20260123-0007",
  "data": {
    "rows": [
      { "user": "RAJA_K", "role": "Z_FI_DISPLAY", "role_count": 8 }
    ],
    "aggregates": [
      { "alias": "role_count", "type": "count_distinct", "value": 8 },
      { "alias": "row_count",  "type": "count",          "value": 142 }
    ]
  },
  "meta": {
    "row_count": 50,
    "total_count": 840,
    "has_more": true,
    "next_page_token": "eyJvZmZzZXQiOjUwfQ==",
    "execution_time_ms": 120,
    "strategy_used": "OPEN_SQL",
    "count_distinct_fallback": false,
    "entity_resolved": "user_access"
  },
  "warnings": [],
  "errors": []
}
```

### 11.2 Aggregates Array Contract

| Field | Type | Description |
|-------|------|-------------|
| `alias` | string | Matches the `alias` in `metrics` |
| `type` | string | Metric type (`count`, `count_distinct`, `sum`, `avg`, `min`, `max`) |
| `value` | number \| null | `null` when no rows matched and metric is non-count |

When `group_by` is present, aggregate values are embedded per row (keyed by alias). The top-level `aggregates` array is populated only for non-grouped aggregate-only queries.

### 11.3 Meta Fields

| Field | Type | Description |
|-------|------|-------------|
| `row_count` | integer | Rows in this response page |
| `total_count` | integer \| null | Total matching rows (`include_summary: true` only) |
| `has_more` | boolean | `true` when more pages are available |
| `next_page_token` | string \| null | Pass to next request `limit.page_token`; `null` on last page |
| `execution_time_ms` | integer | Wall-clock SQL execution time in milliseconds |
| `strategy_used` | enum | `OPEN_SQL`, `NATIVE_SQL`, or `AMDP` |
| `count_distinct_fallback` | boolean | `true` when the COUNT DISTINCT fallback was used |
| `entity_resolved` | string \| null | Entity name if entity mode was used; `null` for raw mode |

---

## 12. ABAP Class Architecture

The engine is implemented as five cooperating ABAP classes.

```
ZCL_JSON_DSL_PARSER
    │  Deserializes raw JSON into ZST_DSL_QUERY. Raises ZCX_DSL_PARSE.
    ▼
ZCL_JSON_DSL_ENTITY_RESOLVER
    │  If entity mode: looks up entity registry, expands sources/joins/fields
    │  into ZST_DSL_QUERY. No-op in raw mode.
    ▼
ZCL_JSON_DSL_VALIDATOR
    │  Phases A, B, C. Returns ZTT_DSL_ERROR. Raises ZCX_DSL_SECURITY.
    ▼
ZCL_JSON_DSL_BUILDER
    │  Compiles condition trees (joins + filters) to dynamic SQL string.
    │  Selects execution strategy based on query features and sy-saprl.
    ▼
ZCL_JSON_DSL_EXECUTOR
       Executes query, applies pagination, writes Flex Mode audit log,
       assembles ZST_DSL_RESPONSE.
```

**Supporting artifacts:**

| Artifact | Type | Purpose |
|----------|------|---------|
| `ZST_DSL_QUERY` | Structure | Typed in-memory DSL representation |
| `ZST_DSL_RESPONSE` | Structure | Typed output; maps to JSON output schema |
| `ZTT_DSL_ERROR` | Table type | Collection of `ZST_DSL_ERROR` entries |
| `ZCX_DSL_PARSE` | Exception | Parse failures; carries error code and position |
| `ZCX_DSL_SECURITY` | Exception | Injection attempts; always triggers audit log entry |
| `ZJSON_DSL_WL` | Custom table | Whitelist; maintained via SM30 view `ZV_DSL_WL` |
| `ZJSON_DSL_ENTITY` | Custom table | Entity registry; maintained via SM30 view `ZV_DSL_ENTITY` |
| `ZJSON_DSL_AUDIT` | Custom table | Flex Mode audit log (see §13) |
| `ZJSON_DSL_CONFIG` | Custom table | Performance guardrail config (`MAX_ROWS_ALLOWED`, `MAX_TIMEOUT_SEC`, etc.); maintained via SM30 view `ZV_DSL_CONFIG` |

**Entry point — facade class:**

```abap
DATA(lo_engine) = NEW zcl_json_dsl_engine( ).
DATA(ls_response) = lo_engine->execute(
  iv_json    = lv_raw_json
  iv_caller  = sy-uname
).
```

`ZCL_JSON_DSL_ENGINE` wires all five classes, catches top-level exceptions, and always returns `ZST_DSL_RESPONSE` — never a raw exception to the caller.

---

## 13. Flex Mode Governance

Flex Mode allows raw SQL expressions in the `derived` array (Phase 3). Because it bypasses the structured validation path, it requires strict governance or it will be blocked by the security team.

### 13.1 Access Control
- Flex Mode is gated by SAP role `ZDSL_ADMIN` — checked at engine startup
- Any query containing a `derived` block without `ZDSL_ADMIN` is rejected with `DSL_WL_ROLE_003`

### 13.2 Audit Log

Every Flex Mode execution writes a record to `ZJSON_DSL_AUDIT`:

| Field | Type | Description |
|-------|------|-------------|
| `AUDIT_ID` | `GUID` | Unique audit record ID |
| `EXEC_TIMESTAMP` | `TIMESTAMP` | UTC execution time |
| `CALLER_USER` | `BNAME` | `sy-uname` of the caller |
| `QUERY_ID` | `CHAR40` | `query_id` from the DSL |
| `QUERY_JSON` | `STRING` | Full raw JSON as submitted |
| `SQL_GENERATED` | `STRING` | Final SQL string passed to execution |
| `STRATEGY_USED` | `CHAR20` | `OPEN_SQL`, `NATIVE_SQL`, or `AMDP` |
| `ROW_COUNT` | `INT4` | Rows returned |
| `EXEC_TIME_MS` | `INT4` | Execution time in milliseconds |
| `STATUS` | `CHAR1` | `S` success, `E` error |
| `ERROR_CODE` | `CHAR30` | First error code if `STATUS = E` |

### 13.3 Retention and Alerting
- Audit records retained for 90 days minimum (configurable via `ZJSON_DSL_CONFIG`)
- Any `DSL_SEC_xxx` error triggers an immediate alert to the security contact defined in config
- Flex Mode usage reports available via transaction `ZJSON_DSL_AUDIT_RPT`

---

## 14. Key Design Decision

### Safe Mode vs Flex Mode

| Mode | Description | Access | Audit |
|------|-------------|--------|-------|
| Safe Mode | Structured JSON only; all fields validated against whitelist | All DSL roles | Standard error log only |
| Flex Mode | Allows raw SQL in `derived` fields (Phase 3) | `ZDSL_ADMIN` only | Full audit log to `ZJSON_DSL_AUDIT` mandatory |

---

## 15. Pros and Cons

### ✅ Pros
- Engine is intentionally dumb — zero business logic or domain knowledge embedded in ABAP
- Competitor obtaining the transport gains a generic query tool, not our product intelligence
- All query definitions, business rules, and processing logic stay inside our network
- Any application stack can call it — Java, Python, Node, curl — via standard HTTPS
- Deployed once per client; our application evolves independently with no client-side changes
- Standardised query interface across all client SAP versions (ECC, S/4HANA)
- Type-safe field binding with currency and quantity companion field support
- Whitelist-first security limits what the engine can access, even if our JSON were intercepted
- AND/OR condition trees support real-world SAP query complexity
- MANDT enforcement prevents cross-client data leakage

### ❌ Cons
- Each new client requires a BASIS transport install and service user setup
- Whitelist must be configured per client (different SAP landscapes may have different table availability)
- Network dependency — requires VPN or IP whitelist from the client; any network change breaks connectivity
- SAP ICF endpoint must be reachable from our network; firewall rules are outside our control
- Performance tuning complexity for large datasets — we see execution time in `meta` but cannot tune the client's SAP
- Debugging failed queries requires correlation between our application logs and SAP ICF logs across two networks
- Offset pagination is client-side on pre-7.40 SAP systems

---

## 16. Strategic Positioning

This engine is not a product — it is an **infrastructure component** that enables our product.

The engine is the bridge. Our intelligence is the product.

> **The engine is the pipe. Our query definitions are the water.**

A competitor who reverse-engineers the ABAP transport sees: a well-built, generic, JSON-driven SAP query executor. Useful, but not a product. They still need to know which tables contain the data that matters, how those tables relate, what conditions define a meaningful result, and how to transform raw SAP data into business insight. That knowledge lives entirely in our application layer, never touches the client's SAP system, and is the actual competitive moat.

This architecture mirrors how the best enterprise SaaS products are structured: Salesforce's reporting engine is generic; the CRM logic is proprietary. Workday's query layer is infrastructure; the HR model is the product. We follow the same pattern for SAP data.

**Comparable infrastructure patterns:**
- Looker's semantic layer (generic execution, proprietary LookML models)
- dbt's query runner (generic; dbt models are the IP)
- SAP BW query engine (generic; InfoProvider definitions are the domain knowledge)

---

## 17. Future Enhancements

- Expression engine (AST-based) — enables Flex Mode derived fields safely
- LLM-driven narrative summaries of query results
- Query result caching (keyed on query hash + params hash)
- Metadata-driven entity discovery (auto-generate entity registry from ABAP Data Dictionary relationships)
- Cross-system federation (S/4HANA + ECC side-by-side via RFC)
- Query plan explain output in `meta` for performance diagnostics
- Entity versioning (entity definitions are versioned; breaking changes raise `DSL_SEM_010`)

---

## 20. HTTP API Contract

This section defines the interface between our external application (Java, Python, Node, or any HTTP client) and the SAP ICF endpoint installed at the client's system.

### 20.1 Endpoint structure

The ICF path is **identical across all client installations**. What varies per client is the host:

```
POST https://<client-sap-host>:<icf-port>/sap/zdsl/query
                └── per client ──────────┘└── fixed ─────┘
```

**Examples:**
```
Client A (ECC):    POST https://sap.acmecorp.internal:8000/sap/zdsl/query
Client B (S/4H):   POST https://erp.betainc.net:44300/sap/zdsl/query
Client C (cloud):  POST https://my123456.s4hana.cloud.sap:443/sap/zdsl/query
```

The SAP ICF handler has no awareness of which client number or which of our products is calling. Client identity is a concern in our application registry, not in SAP. The `X-DSL-Client-ID` header we send is for our own correlation logging — SAP passes it through to the response `meta` but does not use it for routing or access control.

**Our client registry entry (one per client SAP system):**
```json
{
  "client_id": "CLIENT_ACME_001",
  "sap_installation_number": "0020123456",
  "sap_sid": "PRD",
  "sap_endpoint": "https://sap.acmecorp.internal:8000/sap/zdsl",
  "client_secret_ref": "vault://sap-dsl/acme/client_secret",
  "active": true
}
```

### 20.2 Request

```http
POST /sap/zdsl/query HTTP/1.1
Host: sap.client.internal
Content-Type: application/json
Authorization: Bearer <token>
X-DSL-Client-ID: CLIENT_001
X-DSL-Request-ID: req-20260324-00042

{
  "version": "1.3",
  "query_id": "Q-20260324-0001",
  ...DSL payload...
}
```

| Header | Required | Description |
|--------|----------|-------------|
| `Content-Type` | Yes | Must be `application/json` |
| `Authorization` | Yes | `Bearer <token>` — short-lived token issued by the ICF auth endpoint |
| `X-DSL-Client-ID` | Yes | Our identifier for this client installation, used for correlation logging |
| `X-DSL-Request-ID` | Recommended | Our unique request ID for end-to-end tracing across our logs and SAP ICF logs |

### 20.3 Authentication flow

The engine does not implement OAuth itself. Authentication is a two-step process:

**Step 1 — Token request (once per session or on 401):**
```http
POST /sap/zdsl/auth
Content-Type: application/json

{ "client_id": "CLIENT_001", "client_secret": "<secret>" }
```

SAP returns a short-lived bearer token (TTL: 1 hour, configurable in `ZJSON_DSL_CONFIG`). The ICF auth handler maps the `client_id` to the `ZDSL_SVC_USER` technical service user and validates the secret against a hashed credential stored in `ZJSON_DSL_CLIENTS`.

**Step 2 — Query execution:**
All subsequent query requests carry the bearer token in the `Authorization` header. The ICF query handler validates the token, maps it to the service user, and runs the engine under that user's authorizations.

### 20.4 Response

HTTP status codes map to DSL error categories:

| HTTP Status | Condition | DSL Error Range |
|-------------|-----------|-----------------|
| `200 OK` | Success (even if warnings present) | — |
| `400 Bad Request` | Parse or semantic validation failure | `DSL_PARSE_xxx`, `DSL_SEM_xxx` |
| `401 Unauthorized` | Invalid or expired bearer token | — |
| `403 Forbidden` | Caller lacks required SAP role | `DSL_WL_ROLE_003` |
| `429 Too Many Requests` | Guardrail limit exceeded | `DSL_GUARD_001` |
| `500 Internal Server Error` | ABAP runtime exception | `DSL_EXEC_001` |
| `504 Gateway Timeout` | Query exceeded `MAX_TIMEOUT_SEC` | `DSL_EXEC_002` |

A `400` response still returns the full DSL response JSON body with `errors` populated — do not parse HTTP status alone.

### 20.5 Caller examples

**Python (requests):**
```python
import requests

endpoint = "https://sap.client.internal:8000/sap/zdsl/query"
token = get_token()  # your token cache/refresh logic

payload = {
    "version": "1.3",
    "query_id": "Q-001",
    "sources": [{"table": "USR02", "alias": "u"}],
    "select": [{"field": "u.BNAME", "alias": "user", "type": "STRING"}],
    "filters": {
        "logic": "AND",
        "conditions": [{"field": "u.USTYP", "op": "=", "value": "A"}]
    },
    "limit": {"rows": 100}
}

response = requests.post(
    endpoint,
    json=payload,
    headers={
        "Authorization": f"Bearer {token}",
        "X-DSL-Client-ID": "CLIENT_001",
        "X-DSL-Request-ID": "req-001"
    },
    verify=True  # always verify TLS
)
data = response.json()
```

**Node.js (fetch):**
```javascript
const response = await fetch('https://sap.client.internal:8000/sap/zdsl/query', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${token}`,
    'X-DSL-Client-ID': 'CLIENT_001',
    'X-DSL-Request-ID': 'req-001'
  },
  body: JSON.stringify(payload)
});
const data = await response.json();
```

**Java (HttpClient):**
```java
HttpRequest request = HttpRequest.newBuilder()
    .uri(URI.create("https://sap.client.internal:8000/sap/zdsl/query"))
    .header("Content-Type", "application/json")
    .header("Authorization", "Bearer " + token)
    .header("X-DSL-Client-ID", "CLIENT_001")
    .POST(HttpRequest.BodyPublishers.ofString(payloadJson))
    .build();

HttpResponse<String> response = client.send(request,
    HttpResponse.BodyHandlers.ofString());
```

### 20.6 Security rules for our application

- Never embed SAP credentials (username/password) in our application code or config files
- Store client secrets in a secrets manager (HashiCorp Vault, AWS Secrets Manager, or equivalent)
- Cache bearer tokens and refresh proactively before expiry — do not request a new token on every query
- Always use TLS certificate verification — never `verify=False` or equivalent
- The DSL JSON payload must be assembled server-side in our application — never accept raw DSL JSON from an end user and forward it directly to SAP
- Log `X-DSL-Request-ID` in our application logs for every request to enable cross-system tracing

---

## 21. Next Steps

- ~~Define ABAP class architecture~~ ✅ Completed in §12
- Build `ZCL_JSON_DSL_PARSER` — JSON deserialization and structural validation
- Build `ZCL_JSON_DSL_ENTITY_RESOLVER` — entity registry lookup and field expansion
- Build `ZCL_JSON_DSL_VALIDATOR` — all Phase B/C rules including MANDT, pagination ORDER BY, IS NULL, field qualification, guardrails
- Build `ZCL_JSON_DSL_BUILDER` — condition tree compilation, SQL assembly, strategy selection per §8.1
- Build `ZCL_JSON_DSL_EXECUTOR` — query execution, timeout, pagination, audit logging, response assembly
- Build `ZCL_HTTP_DSL_HANDLER` — ICF HTTP handler: receive POST, extract bearer token, call engine, serialise response
- Build `ZCL_HTTP_DSL_AUTH` — ICF auth handler: validate client_id/secret against `ZJSON_DSL_CLIENTS`, issue bearer token
- Create `ZJSON_DSL_WL` + `ZJSON_DSL_ENTITY` + `ZJSON_DSL_AUDIT` + `ZJSON_DSL_CONFIG` + `ZJSON_DSL_CLIENTS` custom tables with SM30 views
- Seed `ZJSON_DSL_CONFIG` with default guardrail values
- Seed entity registry with `user_access` as the first canonical entity
- Define unit test class `ZCL_JSON_DSL_TEST` covering all DSL_xxx error codes
- Performance baseline: Open SQL vs AMDP on USR02 + AGR_USERS with 100k users
- Write Client Installation Guide (BASIS team runbook)
- Write Caller Integration Guide (our application developers)

---

## 19. Sample End-to-End JSON Query

This sample demonstrates v1.2 features: structured join conditions with MANDT, AND/OR filter condition tree, type annotations, and pagination with mandatory ORDER BY.

```json
{
  "version": "1.2",
  "query_id": "Q-20260123-0007",

  "sources": [
    { "table": "USR02", "alias": "u" }
  ],

  "joins": [
    {
      "type": "left",
      "target": { "table": "AGR_USERS", "alias": "ru" },
      "on": {
        "logic": "AND",
        "conditions": [
          { "left": "u.BNAME", "op": "=", "right": "ru.UNAME" },
          { "left": "u.MANDT", "op": "=", "right": "ru.MANDT" }
        ]
      }
    },
    {
      "type": "left",
      "target": { "table": "AGR_1251", "alias": "auth" },
      "on": {
        "logic": "AND",
        "conditions": [
          { "left": "ru.AGR_NAME", "op": "=", "right": "auth.ROLE"  },
          { "left": "ru.MANDT",    "op": "=", "right": "auth.MANDT" }
        ]
      }
    }
  ],

  "select": [
    { "field": "u.BNAME",      "alias": "user",        "type": "STRING" },
    { "field": "ru.AGR_NAME",  "alias": "role",        "type": "STRING" },
    { "field": "auth.OBJECT",  "alias": "auth_object", "type": "STRING" },
    { "field": "ru.FROM_DAT",  "alias": "valid_from",  "type": "DATE"   }
  ],

  "filters": {
    "logic": "AND",
    "conditions": [
      { "field": "u.USTYP",     "op": "IN",  "value": ["A", "B"] },
      { "field": "ru.FROM_DAT", "op": "<=",  "param": "asOfDate"  },
      { "field": "ru.TO_DAT",   "op": ">=",  "param": "asOfDate"  },
      {
        "logic": "OR",
        "conditions": [
          { "field": "u.CLASS", "op": "=", "value": "X" },
          { "field": "u.CLASS", "op": "=", "value": "Y" }
        ]
      }
    ]
  },

  "group_by": ["u.BNAME"],

  "metrics": [
    { "type": "count_distinct", "field": "ru.AGR_NAME", "alias": "role_count" },
    { "type": "count",          "field": "*",            "alias": "row_count"  }
  ],

  "having": [
    { "metric": "role_count", "op": ">", "value": 5 }
  ],

  "order_by": [
    { "field": "role_count", "direction": "desc" }
  ],

  "limit": {
    "rows": 200,
    "offset": 0,
    "page_size": 50,
    "page_token": null
  },

  "params": {
    "asOfDate": "20260123"
  },

  "output": {
    "include_rows": true,
    "include_aggregates": true,
    "include_summary": true
  }
}
```

**Expected response (first page):**

```json
{
  "query_id": "Q-20260123-0007",
  "data": {
    "rows": [
      { "user": "RAJA_K", "role": "Z_FI_DISPLAY", "auth_object": "F_BKPF_BUK", "valid_from": "20240101", "role_count": 14, "row_count": 14 },
      { "user": "SIVA_R", "role": "Z_MM_BUYER",   "auth_object": "M_BEST_BSA", "valid_from": "20240301", "role_count": 9,  "row_count": 9  }
    ],
    "aggregates": []
  },
  "meta": {
    "row_count": 50,
    "total_count": 312,
    "has_more": true,
    "next_page_token": "eyJvZmZzZXQiOjUwfQ==",
    "execution_time_ms": 94,
    "strategy_used": "OPEN_SQL",
    "count_distinct_fallback": false,
    "entity_resolved": null
  },
  "warnings": [],
  "errors": []
}
```

---

---

## 22. Whitelist Modes (v1.5)

The whitelist enforcement supports two modes, configured via `ZJSON_DSL_CONFIG`:

| CONFIG_KEY | CONFIG_VALUE | Description |
|-----------|-------------|-------------|
| `WHITELIST_MODE` | `STRICT` | Default. Every table and field must be pre-registered in `ZJSON_DSL_WL` before queries can access them. Unauthorized access returns `DSL_WL_TABLE_001` or `DSL_WL_FIELD_002`. |
| `WHITELIST_MODE` | `OPEN` | Whitelist checks are skipped entirely. The engine allows any table/field that the SAP service user has standard authorization for. Intended for development/testing environments. |

### Wildcard support (STRICT mode)

In STRICT mode, a wildcard entry allows all fields within a table without listing each one individually:

```
ZJSON_DSL_WL entries:
┌──────────┬───────────┬───────────┐
│ USR02    │ *         │ ZDSL_AUDIT│  ← all fields in USR02 allowed
│ AGR_USERS│ UNAME     │ ZDSL_AUDIT│  ← only UNAME allowed
│ AGR_USERS│ AGR_NAME  │ ZDSL_AUDIT│  ← only AGR_NAME allowed
└──────────┴───────────┴───────────┘
```

### Recommended per-environment settings

| Environment | WHITELIST_MODE | Rationale |
|------------|----------------|-----------|
| Our dev/test SAP | `OPEN` | No friction during development |
| Client QA/sandbox | `STRICT` with wildcards | Test security, less maintenance |
| Client production | `STRICT` with explicit fields | Full audit trail, client approval per field |

---

## 23. Field Access Log (v1.5)

Every query execution writes a field-level access log to `ZJSON_DSL_ALOG`. This log is designed to be shared with the client's security team as a transparent audit trail of what the engine accessed.

### Access log table: `ZJSON_DSL_ALOG`

| Field | Type | Description |
|-------|------|-------------|
| `LOG_ID` | GUID | Unique log entry ID |
| `AUDIT_ID` | GUID | Links to `ZJSON_DSL_AUDIT` for the parent query execution |
| `EXEC_TIMESTAMP` | TIMESTAMP | When the query ran |
| `CALLER_USER` | BNAME | SAP user that executed the query |
| `QUERY_ID` | CHAR40 | Query identifier from the DSL payload |
| `TABLE_NAME` | CHAR30 | SAP table accessed |
| `FIELD_NAME` | CHAR30 | Specific field accessed |
| `ACCESS_TYPE` | CHAR80 | How the field was used: `SELECT`, `FILTER`, or `JOIN` |
| `ROW_COUNT` | INT4 | Number of rows returned by the query |
| `STATUS` | CHAR1 | `S` = success, `E` = error |

### What gets logged per query

For a query like:
```json
{
  "sources": [{"table": "USR02", "alias": "u"}],
  "joins": [{"type": "left", "target": {"table": "AGR_USERS", "alias": "ru"}, "on": ...}],
  "select": [{"field": "u.BNAME"}, {"field": "ru.AGR_NAME"}],
  "filters": {"logic": "AND", "conditions": [{"field": "u.USTYP", "op": "=", "value": "A"}]}
}
```

The access log would contain:

| TABLE_NAME | FIELD_NAME | ACCESS_TYPE |
|-----------|-----------|-------------|
| USR02 | BNAME | SELECT |
| AGR_USERS | AGR_NAME | SELECT |
| USR02 | USTYP | FILTER |
| AGR_USERS | UNAME | JOIN |
| AGR_USERS | MANDT | JOIN |

### Client reporting

The client can query the access log via SE16 on `ZJSON_DSL_ALOG` or a custom report to answer:
- Which tables and fields are being accessed?
- How often is each table queried?
- Which queries return the most rows?
- Are there any error patterns?

This log is always written regardless of `WHITELIST_MODE` setting — even in OPEN mode, every field access is recorded.

---

## 24. Implementation Notes (v1.5)

### Deployment method: abapGit

All ABAP objects are stored in abapGit-compatible format in the Git repository. Import into SAP is done via abapGit — not manual SE24/SE11 or transport.

- FOLDER_LOGIC: PREFIX
- STARTING_FOLDER: /src/
- MASTER_LANGUAGE: E

### Custom tables (updated)

| Table | Description |
|-------|-------------|
| `ZJSON_DSL_WL` | Field whitelist per table (supports wildcard `*`) |
| `ZJSON_DSL_ENTITY` | Semantic entity registry (JSON definitions) |
| `ZJSON_DSL_CONFIG` | Engine configuration and guardrails |
| `ZJSON_DSL_AUDIT` | Query execution audit log |
| `ZJSON_DSL_ALOG` | Field-level access log (client-facing) |
| `ZJSON_DSL_CLNT` | Client credentials (client_id → hashed secret → svc user) |

### ABAP Open SQL specifics

- Field references in generated SQL use tilde notation: `u~BNAME` (not dot `u.BNAME`)
- The builder's `TO_SQL_FIELD` method converts DSL dot notation to ABAP tilde automatically
- Dynamic Open SQL uses old syntax (INTO before FROM) for compatibility with dynamic clauses
- Host variables do not use `@` escape in dynamic SQL context

---

**End of Document — v1.5 (updated 2026-03-24)**
