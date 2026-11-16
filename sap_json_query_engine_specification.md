# SAP JSON Query Engine (DSL) – Functional & Technical Specification

**Spec version:** 1.6 | **Last updated:** 2026-11-16 | **DSL payload versions accepted:** `"1.2"`, `"1.3"`

> **How to read this document.** Sections describe the engine *as implemented* in `src/`. Where the original design defined a rule or error code that the code does not (yet) enforce, it is kept and explicitly marked **"Not enforced in v1.6"** or **"Reserved — not emitted"** so callers do not rely on it.
>
> **Changes in v1.6 (vs v1.5, 2026-03-24):** UNION queries (§5.12) with runtime CTE / in-memory strategy selection (§8); subqueries in `IN` / `NOT IN` promoted from Phase 3 to supported (§5.4.1); `output.debug` diagnostics (§5.11, §11.4); plain-English `hint` enrichment on execution errors (§10.1); metadata pass-through fields (§3); `DSL_SEM_007` (MANDT-required-in-JOIN) removed; new codes `DSL_SEM_012`, `DSL_SEM_013`, `DSL_EXEC_007`, `DSL_ENTITY_001`, `DSL_AUTH_001`–`005`; status of every spec'd-but-unimplemented rule clarified.

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

**Client isolation:** Each client's SAP has its own `ZJSON_DSL_WL` whitelist, its own `ZJSON_DSL_CONFIG` guardrails, and its own `ZJSON_DSL_CLNT` credentials table. Installations are fully isolated — a misconfiguration at one client cannot affect another.

---

## 3. Scope Definition

### ✅ Must Support (Phase 1–2)
- Multi-table SELECT with alias-qualified fields
- JOINs (INNER, LEFT) with multi-condition AND/OR logic (MANDT conditions optional — see §5.2)
- WHERE conditions with logical grouping (AND/OR/nested expression trees)
- Subqueries in `IN` / `NOT IN` filter conditions, one level deep (§5.4.1) — *built in v1.6*
- UNION / UNION ALL of single-source branches (§5.12) — *built in v1.6*
- Aggregations (COUNT, COUNT DISTINCT, SUM, AVG, MIN, MAX)
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

**Subqueries** — ✅ promoted to supported in v1.6 for `IN` / `NOT IN`. See §5.4.1.

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
- Subqueries in `EXISTS`, scalar comparisons, or the SELECT list
- Cross-database joins
- Dynamic schema discovery at runtime
- SQL expressions in the engine: `SUM(CASE ...)`, date arithmetic, percentages. The caller computes these from raw counts / values (this is how the GRC metric catalog is built — see `metrics/README.md`)

---

## 3. JSON DSL Structure (v1.3)

Three query modes are supported. In **entity mode** the caller uses a logical name; in **raw mode** the caller supplies `sources` and `joins` directly; in **union mode** the caller supplies `union.branches`. The engine detects the mode from which key is present.

```json
{
  "version": "1.3",
  "query_id": "",

  "entity": "user_access",

  "sources": [],
  "joins": [],
  "union": {},
  "select": [],
  "filters": {},
  "group_by": [],
  "metrics": [],
  "having": [],
  "order_by": [],
  "limit": {},

  "params": {},
  "output": {},

  "metricName": "", "metricId": "", "priority": "", "description": "", "module": ""
}
```

> - `entity` and `sources`/`joins` are mutually exclusive → `DSL_PARSE_005`.
> - `union` is mutually exclusive with `entity`, `sources` and `joins` → `DSL_PARSE_005`.
> - Exactly one of `entity`, `sources`, `union` is required → `DSL_PARSE_003`.
> - `select` is mandatory except in union mode (where each branch carries its own `select`).
> - Any top-level key not listed above → `DSL_PARSE_004`.

**Metadata pass-through fields** (`metricName`, `metricId`, `priority`, `description`, `module`) are accepted for tracing and logging. They have no effect on the SQL. `metricName`, `metricId`, `priority` and `module` are echoed in the response; `description` is accepted but not echoed. If `query_id` is absent, `metricId` is used as the `query_id`.

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

> ⚠️ **As implemented in v1.6, only `select` aliases are resolved.** `filters`, `group_by` and `order_by` are *not* mapped, so the bare entity aliases in the example below (`user_type`, `valid_from`, `user`) are rejected with `DSL_SEM_011`. Until resolution is extended, use physical alias-qualified fields from the entity definition in those sections (`u.USTYP`, `ru.FROM_DAT`, `u.BNAME`). The entity is loaded from `ZJSON_DSL_ENTITY` (`entity_json`, `active = X`); unknown or inactive entities return `DSL_ENTITY_001`. The JSON-config-file option (`ZJSON_DSL_ENTITIES.json`) was not built.

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

The `on` block uses a **structured condition tree** supporting AND/OR logic. The flat array syntax from v1.0/v1.1 is still accepted and treated as an implicit `AND` node. *Not enforced in v1.6:* the `DSL_DEPR_002` warning is not emitted.

**MANDT is optional in join conditions.** ABAP Open SQL applies client handling automatically, and the builder **strips** any `ON` leaf that references `MANDT` before generating SQL. Callers may include MANDT conditions for readability; they have no effect. The v1.5 rule `DSL_SEM_007` (MANDT required) was **removed** because it rejected legitimate GRC (GRAC) queries — do not re-introduce it.

Every join must name its type (`"inner"` or `"left"`, case-insensitive) and a `target` with `table` and `alias`.

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
- Both tables in any condition must be whitelisted (STRICT mode)
- ON leaves are field-to-field (`left` / `right`). The generated SQL uses tilde notation (`u~BNAME = ru~UNAME`) and `AS` aliases in the FROM / JOIN clause
- Field-vs-field comparison across incompatible DDIC types (e.g. DATS CHAR-8 vs DEC15 timestamp) is rejected by ABAP at runtime. Return both values and compare in the caller

---

### 5.3 Select

Fields carry an optional `type` annotation. **As implemented in v1.6 the annotation is informational:** the executor builds the result structure from the **actual DDIC field types via RTTI** (falling back to `CHAR255` if the DDIC lookup fails), so results are correct whatever `type` is sent. All row values are serialized as JSON strings. *Not enforced in v1.6:* no `DSL_SEM_006` warning when `type` is omitted or unknown.

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
- *Not enforced in v1.6:* `DSL_SEM_008` is not raised; `currency_field` / `unit_field` are parsed but not validated

**Metric / Select separation — strictly enforced:**
- Fields in `select` must be non-aggregate
- Aggregate expressions must only appear in `metrics`
- Every non-aggregate `select` field must appear in `group_by` when `metrics` is non-empty
- Violation raises `DSL_SEM_003`

**Field qualification — strictly enforced:**

Every `field` reference anywhere in the DSL **must** be qualified as `alias.FIELDNAME`. Bare field names without a table alias are rejected with `DSL_SEM_011`. As implemented, `DSL_SEM_011` is checked on `select`, `group_by` and filter leaves; `select` fields are additionally pattern-checked by `DSL_SEC_002`.

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

Generated SQL (params are substituted as escaped, single-quoted literals — see §5.10):
```sql
WHERE u~USTYP IN ( 'A', 'B' )
  AND ru~FROM_DAT <= '20260123'
  AND ru~TO_DAT   >= '20260123'
  AND ( u~CLASS = 'X' OR u~CLASS = 'Y' )
```

**Condition tree schema:**

| Field | Type | Description |
|-------|------|-------------|
| `logic` | enum | `AND` or `OR` at this node |
| `conditions` | array | Mix of leaf conditions and nested condition trees |

**Leaf condition fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `field` | Yes | Table-aliased field, e.g. `u.USTYP`. If absent but `left` is set, `left` is used as the field (lenient parsing) |
| `op` | Yes | Operator from the allowed set (case-insensitive) |
| `value` | One of | Literal value, or array for `IN` / `NOT IN` / `BETWEEN`. Each string ≤ 500 chars (`DSL_SEC_004`) |
| `param` | One of | Key from `params` block. Scalar comparison operators only |
| `subquery` | One of | Nested DSL query; `IN` / `NOT IN` only (§5.4.1) |

**Supported operators:**

| Operator | Value form | Notes |
|----------|-----------|-------|
| `=` `>` `<` `>=` `<=` | scalar `value` or `param` | |
| `!=` | scalar `value` or `param` | ⚠️ Passes validation but **is rejected by ABAP Open SQL on older kernels** (runtime `DSL_EXEC_001`). Use `{"op": "NOT IN", "value": ["X"]}` instead — universally accepted, and used by every GRC metric |
| `IN` / `NOT IN` | array `value`, or `subquery` | Values emitted comma-separated: `IN ( 'A', 'B' )`. A scalar `value` is treated as a one-element list. `param` is not supported |
| `BETWEEN` | array `value` of exactly 2 | `param` is not supported |
| `IS NULL` / `IS NOT NULL` | none | See NULL rules below |

Any other operator (including `<>`, `LIKE`) is rejected with `DSL_SEC_003`.

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
| Initial value vs NULL | SAP stores empty strings as `' '` (space), not NULL. `IS NULL` will not match a space-padded field | *Not enforced in v1.6:* the planned `DSL_EXEC_006` warning is not emitted |
| `IS NULL` in a JOIN condition | Valid syntax but unusual in SAP joins | Permitted; no special restriction |

> ⚠️ In SAP, using `IS NULL` on character fields rarely produces the expected result. The initial value `' '` is not NULL. Consider using `= ' '` (space) or `= '00000000'` for date fields instead.

> **Backward compatibility:** v1.0/v1.1 flat filter arrays are accepted in v1.2 and treated as an implicit top-level `AND` node. Deprecation warning `DSL_DEPR_001` is emitted. Support removed in v2.0.

#### 5.4.1 Subqueries in IN / NOT IN (v1.6)

A filter leaf with `op` `IN` or `NOT IN` may carry a `subquery` instead of a `value` array. The subquery is a full DSL query object, parsed and built recursively by the same parser and builder. `version` may be omitted inside the subquery (`"1.3"` is injected).

```json
{
  "field": "u.BNAME",
  "op": "NOT IN",
  "subquery": {
    "sources": [{ "table": "AGR_USERS", "alias": "su" }],
    "select": [{ "field": "su.UNAME", "alias": "uname" }],
    "filters": {
      "logic": "AND",
      "conditions": [{ "field": "su.AGR_NAME", "op": "=", "value": "Z_ADMIN" }]
    }
  }
}
```

Generated: `u~BNAME NOT IN ( SELECT su~UNAME FROM AGR_USERS AS su WHERE su~AGR_NAME = 'Z_ADMIN' )`

**Rules:**
- `select` must contain exactly one field (SQL requirement; not validated — a wrong column count fails at runtime with `DSL_EXEC_001`)
- The subquery may use `sources`, `joins`, `filters` and `group_by`. `order_by`, `limit`, `having` and `output` are ignored
- `params` inside a subquery are resolved from the subquery's own `params` block, not the outer one
- One level only. A subquery that fails to parse produces SQL that fails at execution (`DSL_EXEC_001`); it is not reported as a parse error
- Any subquery in `filters` switches the whole statement to new Open SQL syntax (see §8.3)
- Tables inside a subquery are not whitelist-checked in v1.6 — keep this in mind for STRICT-mode client systems

---

### 5.5 Group By

```json
"group_by": ["u.BNAME"]
```

The validator strictly enforces: every field in `select` that is not a metric alias must appear in `group_by` when `metrics` is non-empty. Violation raises `DSL_SEM_003`.

---

### 5.6 Metrics

> **COUNT DISTINCT version gate:** `count_distinct` requires NetWeaver 7.40 SP08+ (ABAP release 740). *As implemented in v1.6:* when `sy-saprl < 740` the engine sets `meta.count_distinct_fallback = true`, but the alternative SQL is **not** generated and `DSL_EXEC_003` is not emitted. On a pre-7.40 system, treat `count_distinct` as unsupported.

> ⚠️ **`min` / `max` / `sum` / `avg` on DATS or CHAR fields throw a type error on some kernels** (`DSL_EXEC_001`, with a type-mismatch hint). For "latest date" or "earliest date" style metrics, return the raw rows and compute in the caller.

Metric results are returned as **columns in `data.rows`**, keyed by the metric `alias`. The `data.aggregates` array is only filled for UNION queries (see §11.2).

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
- `metric` must reference an alias defined in the `metrics` array (`DSL_SEM_001`)
- Validator raises `DSL_SEM_002` if `group_by` is absent when `having` is present
- The alias is replaced by its aggregate expression (`COUNT( DISTINCT ru~AGR_NAME ) > 5`)
- `value` is inserted **unquoted** — send a numeric value
- *Not enforced in v1.6:* the `having` operator is not checked against the allowed set. Stick to `=`, `>`, `<`, `>=`, `<=`

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
| `MAX_TIMEOUT_SEC` | `30` | *Not enforced in v1.6* — seeded only. No engine-side timeout; the ICF / work-process timeout applies. `DSL_EXEC_002` is not emitted |
| `WARN_ROWS_THRESHOLD` | `5000` | Rows above this threshold emit warning `DSL_GUARD_002` (large result set) |
| `WARN_JOINS_THRESHOLD` | `3` | Queries with more than this many joins emit warning `DSL_GUARD_003` |
| `OFFSET_LARGE_TABLE_ROWS` | `100000` | *Not enforced in v1.6* — seeded only. `DSL_EXEC_005` is not emitted |
| `CTE_UNION_MODE` | `AUTO` | UNION strategy override: `AUTO` (probe the DB), `FORCE_ON`, `FORCE_OFF`. See §8.2 |
| `WHITELIST_MODE` | `STRICT` | `STRICT` or `OPEN`. See §22. `ZDSL_SEED_CONFIG` seeds `OPEN` for our dev/test system only |
| `TOKEN_TTL_SECONDS` | `3600` | Bearer token lifetime (§20.3) |
| `AUDIT_RETENTION_DAYS` | `90` | Audit log retention (§13.3) |

> **How pagination executes:** the page's offset comes from `limit.offset` or, when present, from `limit.page_token`. The database read is capped with `UP TO offset + page_size + 1 ROWS`; the one extra row is how the engine knows another page exists (`has_more = true`, `next_page_token` = base64 of the next offset). `limit.rows` is the cap across all pages: the read never goes past it, so the last page stops there. Without `page_size` the read is `UP TO rows ROWS` and there is a single page. The offset skip and the page trim happen on the application server.
>
> *Fixed 2026-11-16:* the read used to stop at exactly `offset + page_size` and ignored the token's offset, so `has_more` was always false and page 2 came back empty.

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

The caller cannot override guardrails. *Not built in v1.6:* the planned `ZDSL_ADMIN` temporary override does not exist. Guardrails are changed only by maintaining `ZJSON_DSL_CONFIG`.

> ⚠️ **Offset pagination performance warning:** Offset pagination in Open SQL mode is implemented via client-side row skipping. **Not recommended for tables exceeding `OFFSET_LARGE_TABLE_ROWS`** — the engine fetches all rows up to `offset + page_size` and discards the skipped portion. For large datasets, use AMDP mode (Option 3) with native `LIMIT n OFFSET m`.

> **ORDER BY is mandatory when pagination is active** (see §5.8).

---

### 5.10 Params

```json
"params": {
  "asOfDate": "20260123"
}
```

Params are bound to filter conditions that use `"param": "<key>"`. **As implemented,** the value is substituted into the WHERE clause as a single-quoted literal, with embedded `'` escaped as `''`. Injection safety comes from that escaping plus the Phase C checks (§9.4), not from host-variable binding. There is no type coercion: send values in the field's internal SAP format (DATS `"YYYYMMDD"`, DEC15 timestamp `"YYYYMMDDhhmmss"`, NUMC with leading zeros). In union mode, each branch has its own `params` block.

---

### 5.11 Output Control

```json
"output": {
  "include_rows": true,
  "include_aggregates": true,
  "include_summary": false,
  "debug": false
}
```

| Field | Default | Effect (as implemented in v1.6) |
|-------|---------|---------------------------------|
| `include_rows` | `true` | **UNION queries only:** `false` suppresses `data.rows`, and it is one of the conditions for the `CTE_UNION` path (§8.2). Non-union queries always return rows |
| `include_aggregates` | `true` | **UNION queries only:** controls whether the union `COUNT(*)` appears in `data.aggregates`. Non-union metric values always come back as row columns |
| `include_summary` | `false` | `true` fills `meta.total_count` with the number of rows read before pagination. Otherwise `total_count` is `0` |
| `debug` | `false` | `true` adds a `debug` block to the response: the generated SQL, the strategy, and an **unfiltered** `COUNT(*)` per source table, join target and union-branch table. Built to answer "why did this return zero rows?" in one round trip. Costs one extra `COUNT(*)` per table — do not leave on in production polling |

---

### 5.12 Union (v1.6)

A top-level `union` replaces `entity` / `sources` / `joins` (mutually exclusive → `DSL_PARSE_005`). Top-level `select` is not required.

```json
{
  "version": "1.3",
  "query_id": "M01-total-sod-conflicts",
  "union": {
    "distinct": true,
    "branches": [
      {
        "sources": [{ "table": "GRACUSERACTVL", "alias": "v" }],
        "select": [
          { "field": "v.USERID", "alias": "user_id" },
          { "field": "v.RISKID", "alias": "risk_id" }
        ]
      },
      {
        "sources": [{ "table": "GRACUSERPRMVL", "alias": "v" }],
        "select": [
          { "field": "v.USERID", "alias": "user_id" },
          { "field": "v.RISKID", "alias": "risk_id" }
        ],
        "filters": { "logic": "AND", "conditions": [ ... ] },
        "params": { }
      }
    ]
  },
  "metrics": [{ "type": "count", "field": "*", "alias": "total_conflicts" }],
  "output": { "include_rows": false, "include_aggregates": true }
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `union.distinct` | No (default `true`) | `true` = `UNION DISTINCT` (duplicate rows removed), `false` = `UNION ALL` |
| `union.branches` | Yes (≥ 2) | Each branch has `sources` (one table), `select`, and optional `filters` and `params` |

**Rules:**
- At least 2 branches, each with at least one source and one select field (`DSL_SEM_012`)
- All branches must have the same number of select columns (`DSL_SEM_013`). Each branch's rows are keyed by **that branch's own** select aliases, and DISTINCT de-duplication compares values by position. **Use identical aliases in every branch**, or the rows array will mix key names
- **Branches are single-source.** Only the first `sources` entry is used; `joins` are not supported inside a branch. Alias prefixes are stripped (`v.USERID` becomes `USERID`) because there is nothing to disambiguate
- The only top-level aggregate supported is a single `{"type": "count", "field": "*"}` with no top-level `select` / `group_by`. That is the "count-only" form and the only form eligible for `CTE_UNION`
- **`limit` in union mode (rows).** The returned rows are capped at `limit.page_size` (or `limit.rows`), and `meta.has_more` is set when more may exist. When only rows are wanted, each branch is read with `UP TO <limit> ROWS` (and `SELECT DISTINCT` for UNION DISTINCT), so the merged result still reaches the limit whenever the full union would. When a count is requested as well, the count must be exact, so every qualifying row is read and only the returned rows are cut
- `order_by`, `having`, `offset` and page tokens are not applied to union results
- ⚠️ The in-memory path still reads every qualifying row when an exact DISTINCT count is needed and the CTE path cannot be used. Keep branch filters tight; on large GRC tables this risks `TSV_TNEW_PAGE_ALLOC_FAILED`
- Both rows and the count can be returned in one call (`include_rows: true` + `include_aggregates: true`). That forces the in-memory path

How the engine chooses between `SUM_UNION_ALL`, `CTE_UNION` and `INMEMORY_UNION` is described in §8.2.

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
| `filters[].subquery` | `IN ( SELECT ... )` | One level; forces new Open SQL syntax |
| `union` | `WITH +cte AS ( ... UNION DISTINCT ... )` or N separate SELECTs merged in ABAP | See §8.2 |

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

**UNION**
- Done on the database through an Open SQL CTE only for a 2-branch count where the database supports it; otherwise merged in ABAP memory (§8.2)

### ❌ Not Doable (Without HANA / Native SQL)
- Window functions (ROW_NUMBER, RANK)
- Recursive queries
- General-purpose CTEs (the engine uses a CTE internally only for the 2-branch UNION count, §8.2)
- Complex subqueries beyond one level in SELECT
- JSON processing inside SQL

---

## 8. Execution Strategy Options

### 8.0 What actually runs in v1.6

**Every non-union query executes as dynamic ABAP Open SQL.** `ZCL_JSON_DSL_BUILDER=>DETERMINE_STRATEGY` still applies two of the design-table rules below and labels the query accordingly:

| Rule | Label set in `meta.strategy_used` | What executes |
|------|-----------------------------------|---------------|
| `limit.offset > 0` and `sy-saprl < 740` | `NATIVE_SQL` | Open SQL (Native SQL executor not built) |
| ≥ 3 `metrics` and ≥ 2 `group_by` fields | `AMDP` | Open SQL (AMDP executor not built) |
| Anything else | `OPEN_SQL` | Open SQL |
| `union` present | `SUM_UNION_ALL`, `CTE_UNION` or `INMEMORY_UNION` | See §8.2 |

Callers should treat `NATIVE_SQL` / `AMDP` as "would have escalated". The design table in §8.1 is kept as the target architecture; rules 1–3 and 5 depend on Phase 3 features that don't exist yet.

### 8.1 Decision Table (target design)

| Priority | Condition | Strategy | Reason |
|----------|-----------|----------|--------|
| 1 | Any `derived` field with raw SQL expression present | **Option 3: AMDP** | Raw SQL requires HANA-native execution |
| 2 | `metrics.type = "calc"` (Phase 3 calculated metric) | **Option 3: AMDP** | Arbitrary expressions not safe in Open SQL |
| 3 | Phase 3 subquery with nested `joins` | **Option 3: AMDP** | Complex subquery not expressible in Open SQL |
| 4 | `limit.offset > 0` AND system release < 7.40 SP08 | **Option 2: Native SQL** | No native OFFSET in Open SQL on older releases |
| 5 | `derived` field with simple CONCAT/CASE (no raw SQL) | **Option 2: Native SQL** | Limited derived expression support in Open SQL |
| 6 | Heavy aggregation: `metrics` count ≥ 3 AND `group_by` on 2+ fields AND estimated rows > 500k | **Option 3: AMDP** | HANA columnar engine significantly outperforms ABAP row-by-row for this profile |
| 7 | All other queries | **Option 1: Open SQL** | Default safe path |

> **Row estimates (target design, not built):** The executor would check `mandt_count` from `T000` and use table statistics from `DB02` (if available), or fall back to a whitelist-configured `estimated_rows` hint per table entry. *In v1.6, rule 6 fires on the metric/group-by shape alone; no row estimate is taken.*

### 8.2 UNION execution — CTE_UNION vs INMEMORY_UNION (v1.6)

The executor picks one of two paths at runtime. The choice is reported in `meta.strategy_used`.

**`SUM_UNION_ALL`** (since 2026-11-16) — count-only `UNION ALL` (`distinct: false`) with `include_rows = false`, any number of branches. The count of a UNION ALL is the sum of the branch counts, so the engine runs one `SELECT COUNT(*) FROM <branch> WHERE ...` per branch and adds them. No CTE, no rows on the app server.

**`CTE_UNION`** — a single database round trip:
```sql
WITH +combined AS (
  SELECT f1, f2 FROM TAB_A WHERE ...
  UNION DISTINCT
  SELECT f1, f2 FROM TAB_B WHERE ... )
SELECT COUNT(*) FROM (+combined) INTO @lv_count.
```
Attempted **only when all of these hold:**
1. Count-only query: exactly one metric `{"type":"count","field":"*"}`, no top-level `select` or `group_by`
2. `distinct: true` (the CTE statement is `UNION DISTINCT`)
3. `output.include_rows = false`
4. Exactly 2 branches
5. `ZCL_JSON_DSL_CAPABILITY=>IS_CTE_UNION_SUPPORTED( )` returns true

The capability check runs a tiny `WITH +probe AS ( SELECT mandt FROM t000 UNION DISTINCT SELECT mandt FROM t000 ) SELECT COUNT(*) ...` once per work process and caches the result. `ZJSON_DSL_CONFIG` key `CTE_UNION_MODE` overrides it: `AUTO` (default, probe), `FORCE_ON`, `FORCE_OFF`.

**`INMEMORY_UNION`** — everything else (rows wanted, DISTINCT count with more than 2 branches, no CTE support, or CTE failure). For `distinct: true` each branch is read with `SELECT DISTINCT`; when only rows are wanted each branch is capped with `UP TO <limit> ROWS` (§5.12):
- Each branch is SELECTed separately. The work area is the branch table's own DDIC structure, read with `INTO CORRESPONDING FIELDS`
- Rows are concatenated on the application server
- For `distinct: true`, duplicates are removed by building a `|`-joined value signature per row into a SORTED UNIQUE table
- Rows and the count are computed from the same materialized set, so both can be returned together

**CTE failure is loud, not silent.** If the CTE attempt raises, the engine falls back to in-memory and adds warning **`DSL_EXEC_007`** naming the underlying error. The in-memory path materializes every qualifying row. A silent fall-back into it once hid a broken CTE path for ten commits and risks `TSV_TNEW_PAGE_ALLOC_FAILED` on large tables.

> **Fixed 2026-11-16:** the CTE path used to be taken for `distinct: false` as well and returned the *distinct* count. UNION ALL counts now use `SUM_UNION_ALL`; the CTE is used for `distinct: true` only.

### 8.3 Old vs new Open SQL syntax (v1.6)

The builder sets `needs_new_sql = true` when the query has **JOINs**, a **subquery in filters**, or **both `select` fields and `metrics`**. Otherwise it emits *old* syntax.

| | Old syntax | New (strict) syntax |
|---|---|---|
| Used for | Plain single-table dynamic SELECTs; union in-memory branches | JOINs, subqueries, mixed field + metric selects; the CTE union count |
| Shape | `SELECT (fields) INTO TABLE <t> FROM (from) ...` | `SELECT (fields) FROM (from) ... INTO TABLE @<t>` |
| Dynamic field list | **space**-separated | **comma**-separated |

Mixing the two produces errors that only appear at runtime. A single SQL fragment must never be shared between an old-syntax and a new-syntax consumer. Union branches therefore carry both `select_clause` (space) and `select_clause_csv` (comma), built from one field list.

### 8.4 Strategy Profiles

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

**Whitelist rules (STRICT mode — skipped entirely in OPEN mode, §22):**
- Unlisted table → `DSL_WL_TABLE_001`. Checked for `sources`, `joins` targets and union-branch sources. *Not checked:* tables inside a filter `subquery`
- Unlisted field → `DSL_WL_FIELD_002`. Checked for `select` fields only; a `*` row for the table allows all fields. *Not checked in v1.6:* filter, `group_by`, `order_by` and join fields
- Caller lacks required role → `DSL_WL_ROLE_003`. *Not enforced in v1.6:* the `ROLE` column is not evaluated and the code is never emitted
- Authorization object `Z_DSL_EXEC` with `ACTVT = 16` — *not built in v1.6*
- Whitelist changes require transport; no direct production edits

### 9.2 Phase A — Structural Validation (pre-parse)
- JSON is well-formed (starts with `{`) and `version` is `"1.2"` or `"1.3"`. The HTTP handler first strips any BOM / characters before the first `{`
- Exactly one of `entity`, `sources` or `union` is present; `select` is present unless `union` is used (`DSL_PARSE_003`)
- `entity` and `sources`/`joins` are not both present; `union` is not combined with any of them (`DSL_PARSE_005`)
- No unknown top-level keys (`DSL_PARSE_004`)
- Every condition group carries `logic` (`DSL_PARSE_006`)
- In entity mode, the entity exists and is active in `ZJSON_DSL_ENTITY` (`DSL_ENTITY_001`)

### 9.3 Phase B — Semantic Validation (post-parse)
- Whitelist checks per §9.1 (STRICT mode only)
- All `having` metric references match an alias in `metrics` (`DSL_SEM_001`)
- `group_by` contains all non-aggregate `select` fields when `metrics` is non-empty (`DSL_SEM_003`)
- `having` is only present when `group_by` is non-empty (`DSL_SEM_002`)
- `params` supplies a value for every `"param": "<key>"` reference in filters (`DSL_SEM_004`)
- No duplicate aliases across `select` and `metrics` (`DSL_SEM_005`)
- `order_by` is present when `limit.offset > 0` or `limit.page_token` is non-null (`DSL_SEM_009`)
- `IS NULL` / `IS NOT NULL` conditions do not carry a `value` or `param` (`DSL_SEM_010`)
- Every `select`, `group_by` and filter field is qualified as `alias.FIELDNAME` (`DSL_SEM_011`)
- Union: ≥ 2 branches, each with sources and select fields (`DSL_SEM_012`); equal column count across branches (`DSL_SEM_013`)
- ~~JOIN conditions on client-dependent tables include MANDT (`DSL_SEM_007`)~~ — **removed in v1.6**, see §5.2
- *Not enforced in v1.6:* `type` annotation check / `DSL_SEM_006`; `currency_field` / `unit_field` scope check / `DSL_SEM_008`

### 9.4 Phase C — Injection Defense
- `select` field values match `^[A-Za-z][A-Za-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*$` (enforces the `alias.FIELD` pattern; `DSL_SEC_002`)
- Alias values (in `select`, `metrics`) match `^[A-Za-z][A-Za-z0-9_]*$` (no dot, no space; `DSL_SEC_002`)
- Filter operators matched against the exact allowed set (§5.4); any other operator is rejected (`DSL_SEC_003`)
- Filter string values (scalar and each array element) over 500 characters are rejected (`DSL_SEC_004`)
- All literal and param values are single-quote-escaped by the builder before being placed in SQL
- *Not built in v1.6:* a separate raw-SQL-fragment scan (`DSL_SEC_001`)

> Phase C failures raise `ZCX_DSL_SECURITY` and abort immediately. Phase B collects all errors before returning.

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
| `hint` | string \| null | Suggested remediation. Data element domain `ZDSL_JSON_STR` = `STRG` (unbounded), so long hints and full SQL are never truncated |

**Hint content by stage (v1.6):**
- **Parse errors** — the expected-format hint for that code (e.g. allowed top-level keys, supported versions)
- **Execution errors on the standard path** — `ENRICH_HINT` matches the raw ABAP message to a known pattern, adds a plain-English cause, and always appends `Generated SQL: <statement>`. Patterns covered: rejected boolean expression (usually `!=`, or a cross-type field comparison), data-type mismatch (MIN/MAX on DATS/CHAR, wrongly formatted filter value), unknown column, and dynamic-CTE construction failure
- **Execution errors on the union path** — the hint is the assembled SQL (no pattern enrichment)

### 10.2 Error Code Reference

> The **Emitted** column states whether v1.6 code actually produces the code. "Reserved" codes are defined by the design but never returned. Do not build caller logic around them.

**Parse errors (DSL_PARSE_xxx)**

| Code | Severity | Condition |
|------|----------|-----------|
| `DSL_PARSE_001` | ERROR | Malformed JSON (body doesn't start with `{`, or is empty) |
| `DSL_PARSE_002` | ERROR | Unsupported DSL version (only `"1.2"` / `"1.3"`) |
| `DSL_PARSE_003` | ERROR | Missing mandatory field (`version`; `select`; one of `entity`/`sources`/`union`; `union.branches`) |
| `DSL_PARSE_004` | ERROR | Unknown top-level key |
| `DSL_PARSE_005` | ERROR | `entity` with `sources`/`joins`, or `union` with any of them |
| `DSL_PARSE_006` | ERROR | Condition node missing mandatory `logic` field |

**Entity errors (DSL_ENTITY_xxx)** — *new in v1.6 documentation*

| Code | Severity | Condition |
|------|----------|-----------|
| `DSL_ENTITY_001` | ERROR | Entity name not found, or not active, in `ZJSON_DSL_ENTITY` |

**Whitelist errors (DSL_WL_xxx)** — STRICT mode only

| Code | Severity | Emitted | Condition |
|------|----------|---------|-----------|
| `DSL_WL_TABLE_001` | ERROR | Yes | Table not in whitelist |
| `DSL_WL_FIELD_002` | ERROR | Yes | `select` field not allowed for this table |
| `DSL_WL_ROLE_003` | ERROR | Reserved | Caller lacks required role |

**Semantic errors (DSL_SEM_xxx)**

| Code | Severity | Emitted | Condition |
|------|----------|---------|-----------|
| `DSL_SEM_001` | ERROR | Yes | `having` alias not found in `metrics` |
| `DSL_SEM_002` | ERROR | Yes | `having` present without `group_by` |
| `DSL_SEM_003` | ERROR | Yes | Non-aggregate `select` field missing from `group_by` |
| `DSL_SEM_004` | ERROR | Yes | `param` key in filters not supplied in `params` |
| `DSL_SEM_005` | ERROR | Yes | Duplicate alias in `select` or `metrics` |
| `DSL_SEM_006` | WARNING | Reserved | Unknown `type` annotation — defaulted to `STRING` |
| `DSL_SEM_007` | — | **Removed** | ~~JOIN missing MANDT condition~~. Removed in v1.6 because it blocked legitimate GRAC queries; MANDT ON-conditions are stripped by the builder |
| `DSL_SEM_008` | ERROR | Reserved | `currency_field` or `unit_field` not resolvable in scope |
| `DSL_SEM_009` | ERROR | Yes | Pagination active but `order_by` is absent |
| `DSL_SEM_010` | ERROR | Yes | `IS NULL` / `IS NOT NULL` condition carries a `value` or `param` (must be absent) |
| `DSL_SEM_011` | ERROR | Yes | Field reference is not qualified as `alias.FIELDNAME` |
| `DSL_SEM_012` | ERROR | Yes | Union has fewer than 2 branches, or a branch has no sources / no select fields |
| `DSL_SEM_013` | ERROR | Yes | Union branches have different select column counts |

**Injection / security errors (DSL_SEC_xxx)**

| Code | Severity | Emitted | Condition |
|------|----------|---------|-----------|
| `DSL_SEC_001` | ERROR | Reserved | Raw SQL fragment detected |
| `DSL_SEC_002` | ERROR | Yes | Field or alias contains disallowed characters or fails `alias.FIELD` pattern |
| `DSL_SEC_003` | ERROR | Yes | Filter operator not in allowed set |
| `DSL_SEC_004` | ERROR | Yes | Filter value string exceeds 500 characters |

**Performance guardrail errors (DSL_GUARD_xxx)**

| Code | Severity | Condition |
|------|----------|-----------|
| `DSL_GUARD_001` | ERROR | `limit.rows` exceeds `MAX_ROWS_ALLOWED` system cap |
| `DSL_GUARD_002` | WARNING | Result set likely large — `limit.rows` exceeds `WARN_ROWS_THRESHOLD` |
| `DSL_GUARD_003` | WARNING | Query has more joins than `WARN_JOINS_THRESHOLD`; review for performance |

**Execution errors (DSL_EXEC_xxx)**

| Code | Severity | Emitted | Condition |
|------|----------|---------|-----------|
| `DSL_EXEC_001` | ERROR | Yes | ABAP runtime exception during SQL execution (including RTTI failure on a union branch table). `hint` carries the cause and the generated SQL |
| `DSL_EXEC_002` | ERROR | Reserved | Query exceeded `MAX_TIMEOUT_SEC` execution time limit |
| `DSL_EXEC_003` | WARNING | Reserved | `count_distinct` fallback activated (see `meta.count_distinct_fallback` instead) |
| `DSL_EXEC_004` | WARNING | Reserved | Result set truncated at `limit.rows` cap |
| `DSL_EXEC_005` | WARNING | Reserved | Offset pagination used in Open SQL mode on large table |
| `DSL_EXEC_006` | WARNING | Reserved | `IS NULL` used on a STRING or DATE field |
| `DSL_EXEC_007` | WARNING | Yes | CTE union path failed; fell back to `INMEMORY_UNION`. Message names the underlying failure (§8.2) |

**Deprecation warnings (DSL_DEPR_xxx)**

| Code | Severity | Emitted | Condition |
|------|----------|---------|-----------|
| `DSL_DEPR_001` | WARNING | Yes | Flat filter array used (v1.0/v1.1 syntax); treated as top-level AND. Removed in v2.0 |
| `DSL_DEPR_002` | WARNING | Reserved | Flat `on` array used in join; accepted and treated as AND, but no warning is emitted |

**Authentication errors (DSL_AUTH_xxx)** — returned by the ICF handlers before the engine runs

| Code | HTTP | Endpoint | Condition |
|------|------|----------|-----------|
| `DSL_AUTH_001` | 405 | `/sap/zdsl/auth` | Method other than POST |
| `DSL_AUTH_002` | 400 | `/sap/zdsl/auth` | `client_id` or `client_secret` missing |
| `DSL_AUTH_003` | 401 | `/sap/zdsl/auth` | Invalid credentials, or client inactive / past `valid_to` |
| `DSL_AUTH_004` | 401 | `/sap/zdsl/query` | No token in `X-DSL-Token` or `Authorization: Bearer` |
| `DSL_AUTH_005` | 401 | `/sap/zdsl/query` | Token invalid or expired |

`/sap/zdsl/query` also returns `HTTP_405` for methods other than GET / POST. Auth-stage errors return only an `errors` array (code + message), not the full response envelope.

**Console errors** — `/sap/zdsl/console` only (§20.7). These return the full response envelope.

| Code | HTTP | Condition |
|------|------|-----------|
| `DSL_AUTH_006` | 403 | Logged-on user has no display authorization (`S_TABU_DIS` / `S_TABU_NAM`) for a table in the request. One entry per table, `table` filled |
| `DSL_AUTH_007` | 403 | POST without header `X-DSL-Console: 1` (not sent by the console page — CSRF protection) |
| `DSL_AUTH_008` | 403 | The console is running as a service user from `ZJSON_DSL_CLNT` (SICF node has fixed logon data) |

---

## 11. Output Schema

### 11.1 Full Response Schema

```json
{
  "query_id": "Q-20260123-0007",
  "metricName": "Users with many roles",
  "metricId": "Q-20260123-0007",
  "priority": "High",
  "module": "User Access Review",
  "data": {
    "rows": [
      { "user": "RAJA_K", "role_count": "8" }
    ],
    "aggregates": []
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
  "errors": [],
  "debug": {
    "generated_sql": "SELECT u~BNAME, COUNT( DISTINCT ru~AGR_NAME ) FROM USR02 AS u LEFT OUTER JOIN ...",
    "strategy": "OPEN_SQL",
    "source_counts": [
      { "table": "USR02", "row_count": 4210 },
      { "table": "left join:AGR_USERS", "row_count": 18877 }
    ]
  }
}
```

- `metricName`, `metricId`, `priority`, `module` appear only when they were sent. `description` is not echoed
- **All `data.rows` values are JSON strings**, including numbers and metric results (`"8"`, not `8`), in the SAP internal format: dates `"YYYYMMDD"`, NUMC with leading zeros. The caller converts types
- Each row object is keyed by the `select` alias (or the raw `field` if no alias), followed by the `metrics` aliases
- `debug` is present only when `output.debug: true`

### 11.2 Aggregates Array Contract

| Field | Type | Description |
|-------|------|-------------|
| `alias` | string | Matches the `alias` in `metrics` (`"total"` if none given) |
| `type` | string | `count` |
| `value` | number | Integer count |

**As implemented in v1.6, `data.aggregates` is populated only by UNION count-only queries** (one entry, with `include_aggregates: true`). For every non-union query, metric values, grouped or not, come back as columns in `data.rows`, and `aggregates` is `[]`. An ungrouped count therefore returns one row: `{"total": "142"}`.

### 11.3 Meta Fields

| Field | Type | Description |
|-------|------|-------------|
| `row_count` | integer | Rows in this response page. For a union with only an aggregate, `1` |
| `total_count` | integer | With `include_summary: true`, the rows read up to the end of this page (offset + rows on this page); otherwise `0` (never `null`). It is not a table-wide count |
| `has_more` | boolean | `true` when more pages are available |
| `next_page_token` | string \| null | Pass to next request `limit.page_token`; `null` on last page |
| `execution_time_ms` | integer | Wall-clock execution time in milliseconds |
| `strategy_used` | enum | `OPEN_SQL`, `NATIVE_SQL`, `AMDP` (labels only — see §8.0), `SUM_UNION_ALL`, `CTE_UNION`, `INMEMORY_UNION` |
| `count_distinct_fallback` | boolean | `true` when `count_distinct` is used on a release below 7.40 (§5.6) |
| `entity_resolved` | string \| null | Entity name if entity mode was used; `null` for raw mode |

### 11.4 Debug Block (v1.6)

Present only when `output.debug: true`.

| Field | Type | Description |
|-------|------|-------------|
| `generated_sql` | string | The assembled SELECT statement (tilde notation) |
| `strategy` | string | Builder strategy (`OPEN_SQL` / `NATIVE_SQL` / `AMDP` / `UNION`) |
| `source_counts[]` | array | One entry per source table (`"USR02"`), join target (`"left join:AGR_USERS"`) and union-branch table (`"union:GRACUSERACTVL"`). `row_count` is the **unfiltered** `COUNT(*)` of that table; `-1` means the count itself failed |

**Typical use:** a metric returns zero. If a `source_counts` entry is `0`, the cause is the data, not the query. For example, `GRACACTUSAGE` is empty until the `GRAC_ACTION_USAGE_SYNC` job has run. If every table has rows, the filters or join keys are the cause.

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
       Executes query, applies pagination, writes audit + access logs,
       chooses CTE_UNION / INMEMORY_UNION, enriches error hints, populates
       the debug block, assembles the response.
```

**As built (v1.6) — 13 classes, 1 interface, 2 reports in package `ZDL_JSON_DSL`:**

| Object | Role |
|--------|------|
| `ZIF_JSON_DSL_TYPES` | **The contract.** All shared types: `ty_query`, `ty_response`, `ty_cond_node`, `ty_union`, `ty_debug_info`, ... |
| `ZCL_JSON_DSL_ENGINE` | Facade: parse → resolve → validate → build → execute. Always returns a response, never an exception. Also `GET_TEMPLATE` (the GET payload) |
| `ZCL_JSON_DSL_PARSER` | Hand-rolled character-level JSON scanner (no `/ui2/cl_json` dependency, so it runs on any release). Whitespace detection uses Unicode code points |
| `ZCL_JSON_DSL_ENTITY_RESOLVER` | Entity name → sources / joins / fields |
| `ZCL_JSON_DSL_VALIDATOR` | Whitelist, semantic, guardrail, union and injection checks |
| `ZCL_JSON_DSL_BUILDER` | Condition trees → SQL; old/new syntax switch; union branch SQL (both separators); subquery recursion |
| `ZCL_JSON_DSL_EXECUTOR` | Dynamic SELECT with RTTI result types, pagination, union paths, audit/access log, hints, debug |
| `ZCL_JSON_DSL_CAPABILITY` | Runtime CTE+UNION probe against T000, cached per work process, overridable via `CTE_UNION_MODE` |
| `ZCL_HTTP_DSL_HANDLER` | ICF `/sap/zdsl/query`: POST = query, GET = template |
| `ZCL_HTTP_DSL_AUTH` | ICF `/sap/zdsl/auth`: client_id / secret → bearer token |
| `ZCL_JSON_DSL_TEST` | ABAP Unit tests |
| `ZCX_DSL_PARSE`, `ZCX_DSL_SECURITY` | Exception classes |
| `ZDSL_SEED_CONFIG` (report) | Seeds `ZJSON_DSL_CONFIG` and the `user_access` entity |
| `ZDSL_SETUP_ICF` (report) | Registers the ICF nodes |

> **Condition trees are flattened.** ABAP has no recursive structure types, so the JSON tree is stored as a flat table of `ty_cond_node` (`node_id`, `parent_id`, `node_type` `G`=group / `L`=leaf). `BUILD_CONDITION_SQL` rebuilds the nesting by walking `parent_id`.

**Supporting artifacts (original design names — the as-built types live in `ZIF_JSON_DSL_TYPES`):**

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

`ZCL_JSON_DSL_ENGINE` wires the pipeline, catches top-level exceptions, and always returns a response structure — never a raw exception to the caller.

---

## 13. Flex Mode Governance

Flex Mode allows raw SQL expressions in the `derived` array (Phase 3). Because it bypasses the structured validation path, it requires strict governance or it will be blocked by the security team.

### 13.1 Access Control
- Flex Mode is gated by SAP role `ZDSL_ADMIN` — checked at engine startup
- Any query containing a `derived` block without `ZDSL_ADMIN` is rejected with `DSL_WL_ROLE_003`

### 13.2 Audit Log

*As implemented in v1.6 (Flex Mode is not built), **every** executed query writes a record to `ZJSON_DSL_AUDIT`, plus field-level rows to `ZJSON_DSL_ALOG` (§23). `STRATEGY_USED` holds `OPEN_SQL` / `NATIVE_SQL` / `AMDP` / `UNION`.* Planned record layout:

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
- Audit records retained for 90 days minimum (`AUDIT_RETENTION_DAYS` in `ZJSON_DSL_CONFIG`). *Not built in v1.6:* an automatic purge job
- *Not built in v1.6:* the alert to a security contact on `DSL_SEC_xxx`
- *Not built in v1.6:* transaction `ZJSON_DSL_AUDIT_RPT`. Use SE16 on `ZJSON_DSL_AUDIT` / `ZJSON_DSL_ALOG`

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

The SAP ICF handler has no awareness of which client number or which of our products is calling. Client identity is a concern in our application registry, not in SAP. The `X-DSL-Client-ID` header we send is for our own correlation logging. *As implemented in v1.6, SAP ignores it: it is not echoed in `meta` and not logged.*

**Endpoints:**

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/sap/zdsl/auth` | `client_id` + `client_secret` → bearer token |
| `POST` | `/sap/zdsl/query` | Execute a DSL query (bearer token required) |
| `GET` | `/sap/zdsl/query` | Self-documenting: returns `{"message": "...", "template": {<valid example payload>}}`. No token required |

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
| `X-DSL-Token` | Yes* | The bearer token (raw, no `Bearer ` prefix). **Preferred**: the SAP ICF layer consumes the standard `Authorization` header for its own logon in many configurations |
| `Authorization` | Yes* | `Bearer <token>`. Fallback, read only when `X-DSL-Token` is absent. Works when the ICF node uses anonymous / service logon |
| `X-DSL-Client-ID` | Recommended | Our identifier for this client installation. Our side only; ignored by SAP in v1.6 |
| `X-DSL-Request-ID` | Recommended | Our unique request ID for tracing. Our side only; ignored by SAP in v1.6 |

\* One of `X-DSL-Token` or `Authorization` is required.

### 20.3 Authentication flow

The engine does not implement OAuth itself. Authentication is a two-step process:

**Step 1 — Token request (once per session or on 401):**
```http
POST /sap/zdsl/auth
Content-Type: application/json

{ "client_id": "CLIENT_001", "client_secret": "<secret>" }
```

Response:
```json
{ "access_token": "<token>", "token_type": "Bearer", "expires_in": 3600 }
```

The ICF auth handler hashes the secret and looks up `ZJSON_DSL_CLNT` for a row with that `client_id` and hash, `active = X` and `valid_to >= today`. That row's `svc_user` is the service user the token maps to. TTL comes from `TOKEN_TTL_SECONDS` in `ZJSON_DSL_CONFIG` (default 3600). Errors: `DSL_AUTH_001`–`003` (§10.2).

**Step 2 — Query execution:**
All subsequent query requests carry the token in the `X-DSL-Token` header (or `Authorization: Bearer`). The ICF query handler validates the token and maps it to the service user, which is passed to the engine as the caller for audit logging. Missing token → `DSL_AUTH_004`; invalid or expired → `DSL_AUTH_005` (both HTTP 401). On 401, request a new token and retry once.

### 20.4 Response

HTTP status codes map to DSL error categories:

| HTTP Status | Condition | DSL Error Range |
|-------------|-----------|-----------------|
| `200 OK` | Success (even if warnings present) | — |
| `400 Bad Request` | Parse, semantic or injection validation failure | `DSL_PARSE_xxx`, `DSL_SEM_xxx`, `DSL_SEC_xxx`, `DSL_AUTH_002` |
| `401 Unauthorized` | Missing, invalid or expired token; bad credentials | `DSL_AUTH_003`–`005` |
| `403 Forbidden` | Caller lacks required SAP role | `DSL_WL_ROLE_003` (reserved — not reachable in v1.6) |
| `405 Method Not Allowed` | Wrong HTTP method | `HTTP_405`, `DSL_AUTH_001` |
| `429 Too Many Requests` | Guardrail limit exceeded | `DSL_GUARD_001` |
| `500 Internal Server Error` | ABAP runtime exception, or any other error code | `DSL_EXEC_001`, `DSL_WL_TABLE_001`, `DSL_WL_FIELD_002`, `DSL_ENTITY_001` |
| `504 Gateway Timeout` | Query exceeded `MAX_TIMEOUT_SEC` | `DSL_EXEC_002` (reserved — not reachable in v1.6) |

Status is mapped from the **first** error in `errors`. A `4xx`/`5xx` response from `/sap/zdsl/query` (after authentication) still returns the full DSL response JSON body with `errors` populated — do not parse HTTP status alone.

> Note: whitelist and entity errors currently map to **500** because no specific rule matches them. Callers should branch on `errors[0].code`, not on the status.

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

### 20.7 Query Console — `/sap/zdsl/console` (v1.6)

A browser page served by the SAP system itself, for people who are logged on to SAP: paste or open a DSL request, run it, read and save the response. Handler `ZCL_HTTP_DSL_CONSOLE`; node registered by `ZDSL_SETUP_ICF` (checkbox `P_CONS`).

| Method | Behaviour |
|--------|-----------|
| `GET` | Returns the page. The HTML is built in ABAP (`GET_PAGE_LINES`), with the user, system, client and whitelist mode filled in |
| `POST` | Runs the posted DSL JSON **as the logged-on user** through `ZCL_JSON_DSL_ENGINE` and returns the same JSON envelope and status codes as `/sap/zdsl/query` |

**Two run modes on the page:**
- **My SAP user** (default) — posts to `/sap/zdsl/console`. No token. The audit log records the person's user name
- **Service client** — the page calls `/sap/zdsl/auth` then `/sap/zdsl/query` with `client_id` / `client_secret`, exactly like our external application. Used to test that path from inside the client's network

**Security rules (My SAP user mode):**
- The SICF node has **no fixed logon data** — the standard SAP logon applies. If the handler finds itself running as a service user listed in `ZJSON_DSL_CLNT`, it refuses (`DSL_AUTH_008`) and the page disables this mode
- **Table authorization.** Open SQL does not check table authorizations, so before executing, the console collects every table the request reads — `sources`, `joins`, union branches, IN / NOT IN subqueries, and the tables behind an `entity` — and calls `VIEW_AUTHORITY_CHECK` (action `S`) for each: `S_TABU_DIS` for the table's authorization group or `S_TABU_NAM` for the table, the same check as SE16. Any failure stops the request with one `DSL_AUTH_006` per table. `SU53` shows the failed check
- The engine's whitelist (`WHITELIST_MODE`) still applies on top
- **CSRF:** the POST must carry `X-DSL-Console: 1` (`DSL_AUTH_007` otherwise)
- The page sends `Cache-Control: no-store`, `X-Frame-Options: SAMEORIGIN`, `X-Content-Type-Options: nosniff`

**Page features:** request text area with JSON check, examples (generic only — the metric catalog is never shipped to a client system), open request from a local file, engine template from `GET /sap/zdsl/query`; overrides for `output.include_rows` / `include_aggregates` / `include_summary` / `debug`, `limit.rows` / `page_size`, `version`, `query_id`; response text area plus Rows, Messages (with hints), Debug (row counts per table, generated SQL) and Sent-request views; save every response automatically as a `.json` file with a configurable name pattern (`{query_id}_{yyyyMMdd-HHmmss}_{status}.json`), optionally with the request included; session history. Settings are kept in the browser's local storage; the client secret and token are never stored.

**Editing the page:** the HTML source is `web/dsl_console.html` (ASCII only, lines ≤ 200 chars). `python tools/gen_console_abap.py` regenerates the `APPEND` block in `ZCL_HTTP_DSL_CONSOLE=>GET_PAGE_LINES`. Never edit the generated block by hand.

---

## 21. Next Steps

**Done (v1.6, verified end-to-end in a live SAP system):**
- ~~Define ABAP class architecture~~ ✅ §12
- ~~Parser, entity resolver, validator, builder, executor, facade~~ ✅
- ~~ICF query handler and auth handler~~ ✅
- ~~Custom tables `ZJSON_DSL_WL` / `ENTITY` / `AUDIT` / `ALOG` / `CONFIG` / `CLNT` with maintenance objects~~ ✅
- ~~Seed config + `user_access` entity (`ZDSL_SEED_CONFIG`); ICF registration (`ZDSL_SETUP_ICF`)~~ ✅
- ~~Unit test class `ZCL_JSON_DSL_TEST`~~ ✅ (does not yet cover every DSL_xxx code)
- ~~Subqueries in IN / NOT IN; UNION with CTE / in-memory strategies; debug block; hint enrichment~~ ✅
- ~~Client Installation Guide, Caller Integration Guide~~ ✅
- ~~26-KPI GRC metric catalog (`metrics/`) as pure DSL payloads~~ ✅

**Open:**
- ~~Fix: CTE union path ignores `distinct: false`~~ ✅ 2026-11-16 (`SUM_UNION_ALL`)
- Fix: `DSL_PARSE_004` / `DSL_PARSE_003` hint text doesn't mention `union` or the metadata keys
- Decide: map `DSL_WL_*` / `DSL_ENTITY_001` to 403 / 400 instead of 500 (§20.4)
- Apply the whitelist to filter / join / subquery fields in STRICT mode (§9.1). Needed before a client production go-live
- ~~Apply `limit` to union in-memory branches~~ ✅ 2026-11-16 (§5.12)
- Implement or formally drop the reserved codes: `SEM_006`, `SEM_008`, `SEC_001`, `EXEC_002`–`006`, `WL_ROLE_003`, `DEPR_002`
- Performance baseline: Open SQL vs AMDP on USR02 + AGR_USERS with 100k users

---

## 19. Sample End-to-End JSON Query

This sample demonstrates v1.2 features: structured join conditions (the MANDT leaves are optional and stripped by the builder), AND/OR filter condition tree, type annotations, and pagination with mandatory ORDER BY.

> ⚠️ As written, this sample fails validation with `DSL_SEM_003`, because `role`, `auth_object` and `valid_from` are selected but not in `group_by`. It is kept to show every feature in one payload. To run it, either add those fields to `group_by` or drop them from `select`.

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
      { "user": "RAJA_K", "role": "Z_FI_DISPLAY", "auth_object": "F_BKPF_BUK", "valid_from": "20240101", "role_count": "14", "row_count": "14" },
      { "user": "SIVA_R", "role": "Z_MM_BUYER",   "auth_object": "M_BEST_BSA", "valid_from": "20240301", "role_count": "9",  "row_count": "9"  }
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
- **Old vs new syntax is switched deliberately** (§8.3). Old syntax (INTO before FROM, no `@`, space-separated fields) is used for plain single-table SELECTs. New syntax (commas, `@` host variables) is used for JOINs, subqueries and mixed field+metric SELECTs. Never share one fragment between the two
- `AS` **is required** in FROM / JOIN clauses for alias resolution, and must **not** appear in the dynamic SELECT field list (old syntax maps results by position)
- The result structure is built from **DDIC types via RTTI**, wrapped in TRY/CATCH. `STRING` targets fail in old syntax
- Union branches use the DDIC table structure + `INTO CORRESPONDING FIELDS`
- `IN` lists are comma-separated; `ORDER BY` / `GROUP BY` / `HAVING` keywords are only appended when non-empty
- Pretty-printed JSON is supported: number/boolean scanning stops at whitespace / CR / LF

### Version history

| Version | Date | Summary |
|---------|------|---------|
| 1.6 | 2026-11-16 | Spec realigned with code: UNION + CTE/in-memory strategies, subqueries, debug block, hint enrichment, metadata pass-through, `DSL_SEM_007` removed, new codes, as-implemented status of every rule |
| 1.5 | 2026-03-24 | Whitelist modes, field access log, abapGit implementation notes |

---

**End of Document — v1.6 (updated 2026-11-16)**
