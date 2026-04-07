# SAP JSON DSL Engine — JSON Parameter Reference

**Version:** 1.3 | **Last Updated:** 2026-04-07

---

## Quick Example

```json
{
  "version": "1.3",
  "query_id": "Q-001",
  "metricName": "User Count",
  "metricId": "user-count",
  "priority": "High",
  "description": "Count of dialog users",
  "module": "User Access Review",
  "sources": [{"table": "USR02", "alias": "u"}],
  "joins": [{
    "type": "left",
    "target": {"table": "AGR_USERS", "alias": "ru"},
    "on": {"logic": "AND", "conditions": [
      {"left": "u.BNAME", "op": "=", "right": "ru.UNAME"},
      {"left": "u.MANDT", "op": "=", "right": "ru.MANDT"}
    ]}
  }],
  "select": [
    {"field": "u.BNAME", "alias": "user", "type": "STRING"},
    {"field": "ru.AGR_NAME", "alias": "role", "type": "STRING"}
  ],
  "metrics": [
    {"type": "count", "field": "*", "alias": "total"}
  ],
  "filters": {
    "logic": "AND",
    "conditions": [
      {"field": "u.USTYP", "op": "IN", "value": ["A", "B"]},
      {"field": "ru.TO_DAT", "op": ">=", "param": "cutoff"},
      {"logic": "OR", "conditions": [
        {"field": "u.BNAME", "op": "=", "value": "ADMIN"},
        {"field": "u.BNAME", "op": "=", "value": "SUPER"}
      ]}
    ]
  },
  "group_by": ["u.BNAME"],
  "having": [{"metric": "total", "op": ">", "value": "5"}],
  "order_by": [{"field": "u.BNAME", "direction": "asc"}],
  "limit": {"rows": 100, "page_size": 50},
  "params": {"cutoff": "20260101"},
  "output": {"include_rows": true, "include_aggregates": true, "include_summary": false}
}
```

---

## All Parameters

### Top-Level — Required

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `version` | string | **Yes** | DSL version. Must be `"1.2"` or `"1.3"` |
| `select` | array | **Yes** | Fields to retrieve (at least one entry) |
| `sources` | array | **Yes*** | Base tables in raw mode |
| `entity` | string | **Yes*** | Semantic entity name in entity mode |

\* One of `sources` or `entity` is required. They are mutually exclusive.

### Top-Level — Optional

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query_id` | string | No | Unique query identifier for tracing. Auto-filled from `metricId` if absent |
| `joins` | array | No | JOIN definitions |
| `filters` | object | No | WHERE conditions as AND/OR condition tree |
| `group_by` | array | No | GROUP BY field list |
| `metrics` | array | No | Aggregate functions (COUNT, SUM, etc.) |
| `having` | array | No | HAVING conditions on metric aliases |
| `order_by` | array | No | Sort order. **Mandatory** when using pagination offset |
| `limit` | object | No | Row limiting and pagination |
| `params` | object | No | Parameter values for param-referenced filters |
| `output` | object | No | Controls what the response includes |

### Top-Level — Metadata (pass-through)

These fields are accepted, stored, and returned in the response for tracing/logging purposes.

| Parameter | Type | Description |
|-----------|------|-------------|
| `metricName` | string | Human-readable metric name |
| `metricId` | string | Metric identifier. Used as `query_id` if `query_id` is absent |
| `priority` | string | Metric priority (e.g. Critical, High, Medium, Low) |
| `description` | string | Metric description |
| `module` | string | Source module name (e.g. Access Risk Analysis, UAR) |

---

## Parameter Details

### `sources` — Base Tables

```json
"sources": [
  {"table": "USR02", "alias": "u"}
]
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `table` | string | Yes | SAP database table name |
| `alias` | string | Yes | Short alias used in all field references |

- First entry is the base (FROM) table
- All field references must use the alias: `u.BNAME`, not `USR02.BNAME` or `BNAME`

---

### `joins` — JOIN Definitions

```json
"joins": [{
  "type": "left",
  "target": {"table": "AGR_USERS", "alias": "ru"},
  "on": {"logic": "AND", "conditions": [
    {"left": "u.BNAME", "op": "=", "right": "ru.UNAME"},
    {"left": "u.MANDT", "op": "=", "right": "ru.MANDT"}
  ]}
}]
```

| Field | Type | Required | Values |
|-------|------|----------|--------|
| `type` | string | Yes | `"inner"` or `"left"` |
| `target.table` | string | Yes | Table to join |
| `target.alias` | string | Yes | Alias for the joined table |
| `on` | object | Yes | Condition tree (see Condition Trees below) |

**Join ON condition leaf:**

| Field | Type | Description |
|-------|------|-------------|
| `left` | string | Left side field: `alias.FIELD` |
| `op` | string | Operator (usually `"="`) |
| `right` | string | Right side field: `alias.FIELD` |

- MANDT conditions are included in the JSON but automatically handled by SAP
- Multiple JOINs are supported (chain: A → B → C)

---

### `select` — Fields to Retrieve

```json
"select": [
  {"field": "u.BNAME", "alias": "user", "type": "STRING"},
  {"field": "u.ERDAT", "alias": "created", "type": "DATE"},
  {"field": "doc.NETWR", "alias": "amount", "type": "AMOUNT", "currency_field": "doc.WAERS"}
]
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `field` | string | Yes* | Alias-qualified field: `alias.FIELDNAME` |
| `alias` | string | Yes* | Output column name in response |
| `type` | string | No | Type annotation (defaults to STRING) |
| `currency_field` | string | No | Companion currency field (for AMOUNT type) |
| `unit_field` | string | No | Companion unit field (for QUANTITY type) |

\* In entity mode, only `alias` is required (field is resolved from entity definition).

**Supported type annotations:**

| Type | SAP Type | Notes |
|------|----------|-------|
| `STRING` | CHAR | Default |
| `DATE` | DATS | Format: YYYYMMDD |
| `NUMBER` | INT/NUMC | Integer or numeric |
| `AMOUNT` | CURR | Requires `currency_field` |
| `CURRENCY` | CUKY | Currency key (e.g. USD) |
| `QUANTITY` | QUAN | Requires `unit_field` |
| `UNIT` | UNIT | Unit of measure |
| `BOOLEAN` | CHAR(1) | X = true, space = false |
| `TIMESTAMP` | DEC(15) | UTC timestamp |

---

### `filters` — WHERE Conditions (Condition Tree)

```json
"filters": {
  "logic": "AND",
  "conditions": [
    {"field": "u.USTYP", "op": "=", "value": "A"},
    {"field": "u.USTYP", "op": "IN", "value": ["A", "B"]},
    {"field": "u.TRDAT", "op": ">=", "param": "startDate"},
    {"field": "u.CLASS", "op": "IS NULL"},
    {"logic": "OR", "conditions": [
      {"field": "u.BNAME", "op": "=", "value": "ADMIN"},
      {"field": "u.BNAME", "op": "=", "value": "SUPER"}
    ]}
  ]
}
```

**Condition tree node (group):**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `logic` | string | **Yes** | `"AND"` or `"OR"` — how child conditions combine |
| `conditions` | array | **Yes** | Mix of leaf conditions and nested groups |

**Condition leaf:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `field` | string | Yes | Alias-qualified: `alias.FIELDNAME` |
| `op` | string | Yes | Operator (see table below) |
| `value` | string/array | One of* | Literal value or array for IN |
| `param` | string | One of* | Key from `params` block |

\* Use `value` for literal values, `param` for parameterized values. Omit both for IS NULL/IS NOT NULL.

**Supported operators:**

| Operator | Value Type | Example |
|----------|-----------|---------|
| `=` | scalar | `"value": "A"` |
| `!=` | scalar | `"value": "B"` |
| `>` | scalar | `"value": "100"` |
| `<` | scalar | `"value": "50"` |
| `>=` | scalar | `"value": "20260101"` |
| `<=` | scalar | `"value": "20261231"` |
| `IN` | array | `"value": ["A", "B", "C"]` |
| `NOT IN` | array | `"value": ["X", "Y"]` |
| `IS NULL` | none | No value or param |
| `IS NOT NULL` | none | No value or param |
| `BETWEEN` | array(2) | `"value": ["100", "999"]` |

- Nesting depth is unlimited: AND inside OR inside AND, etc.
- The top-level `filters` must always have `logic` and `conditions`

---

### `metrics` — Aggregation Functions

```json
"metrics": [
  {"type": "count", "field": "*", "alias": "row_count"},
  {"type": "count_distinct", "field": "ru.AGR_NAME", "alias": "role_count"},
  {"type": "sum", "field": "doc.NETWR", "alias": "total_amount"}
]
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | Aggregation type |
| `field` | string | Yes | Field to aggregate (`*` for count all) |
| `alias` | string | Yes | Result column name |

**Supported aggregation types:**

| Type | SQL Generated | Notes |
|------|--------------|-------|
| `count` | `COUNT(*)` or `COUNT(field)` | Use `"field": "*"` for all rows |
| `count_distinct` | `COUNT(DISTINCT field)` | Requires NW 7.40 SP08+ |
| `sum` | `SUM(field)` | Numeric fields only |
| `avg` | `AVG(field)` | Numeric fields only |
| `min` | `MIN(field)` | Any comparable field |
| `max` | `MAX(field)` | Any comparable field |

- When `metrics` is present, every field in `select` must appear in `group_by`
- Metric aliases can be used in `having` and `order_by`

---

### `group_by` — Group By

```json
"group_by": ["u.BNAME", "u.USTYP"]
```

- Array of alias-qualified field names
- Required when `metrics` is present and `select` has non-aggregate fields
- Every `select` field must appear in `group_by` when using metrics

---

### `having` — Having Conditions

```json
"having": [
  {"metric": "role_count", "op": ">", "value": "5"}
]
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `metric` | string | Yes | Must match an alias in `metrics` |
| `op` | string | Yes | Comparison operator |
| `value` | string/number | Yes | Threshold value |

- Only valid when `group_by` is present
- Filters on aggregated values (after GROUP BY)

---

### `order_by` — Sort Order

```json
"order_by": [
  {"field": "u.BNAME", "direction": "asc"},
  {"field": "role_count", "direction": "desc"}
]
```

| Field | Type | Required | Values |
|-------|------|----------|--------|
| `field` | string | Yes | Field name or metric alias |
| `direction` | string | Yes | `"asc"` or `"desc"` |

- **Mandatory** when `limit.offset > 0` or `limit.page_token` is set
- Can reference metric aliases (e.g. sort by count)

---

### `limit` — Row Limiting & Pagination

```json
"limit": {
  "rows": 100,
  "page_size": 50,
  "offset": 0,
  "page_token": null
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `rows` | integer | — | Maximum rows to return. Cannot exceed system MAX_ROWS_ALLOWED (default 10000) |
| `page_size` | integer | = rows | Rows per page |
| `offset` | integer | 0 | Skip this many rows |
| `page_token` | string | null | Opaque token from previous response for next page |

**Pagination flow:**
1. First call: `{"rows": 100, "page_size": 50}` → returns first 50 rows + `next_page_token`
2. Next call: `{"rows": 100, "page_size": 50, "page_token": "eyJ..."}` → returns next 50 rows
3. Repeat until `meta.has_more = false`

---

### `params` — Parameter Binding

```json
"params": {
  "startDate": "20260101",
  "endDate": "20261231",
  "userType": "A"
}
```

- Key-value pairs where keys match `param` references in filter conditions
- Values are bound safely at execution time (prevents SQL injection)
- All values are strings — type coercion is handled by the engine
- Every `param` referenced in filters must have a corresponding entry

---

### `output` — Response Control

```json
"output": {
  "include_rows": true,
  "include_aggregates": true,
  "include_summary": false
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `include_rows` | boolean | true | Include data rows in response |
| `include_aggregates` | boolean | true | Include aggregate results |
| `include_summary` | boolean | false | Include total_count in meta |

---

### `entity` — Entity Mode (alternative to sources/joins)

```json
{
  "version": "1.3",
  "entity": "user_access",
  "select": [
    {"alias": "user"},
    {"alias": "role"}
  ]
}
```

- Uses a pre-defined entity from `ZJSON_DSL_ENTITY` table
- Entity definition contains sources, joins, and field mappings
- `select` entries reference entity field aliases (not table.FIELD)
- Cannot be combined with `sources` or `joins`

---

## Response Structure

```json
{
  "query_id": "Q-001",
  "metricName": "...",
  "metricId": "...",
  "priority": "...",
  "module": "...",
  "data": {
    "rows": [
      {"user": "ADMIN", "role": "Z_ADMIN", "total": "5"}
    ],
    "aggregates": []
  },
  "meta": {
    "row_count": 1,
    "total_count": 0,
    "has_more": false,
    "next_page_token": null,
    "execution_time_ms": 15,
    "strategy_used": "OPEN_SQL",
    "count_distinct_fallback": false,
    "entity_resolved": null
  },
  "warnings": [],
  "errors": []
}
```

| Field | Description |
|-------|-------------|
| `data.rows` | Array of objects, each key is the select alias |
| `data.aggregates` | Aggregate-only results (when no GROUP BY) |
| `meta.row_count` | Rows in this page |
| `meta.has_more` | true if more pages available |
| `meta.next_page_token` | Pass to next request for pagination |
| `meta.execution_time_ms` | SQL execution time |
| `meta.strategy_used` | OPEN_SQL, NATIVE_SQL, or AMDP |
| `warnings` | Non-fatal issues (guardrail thresholds, deprecations) |
| `errors` | Fatal issues (query not executed) |

---

## Error Codes

| Category | Codes | Meaning |
|----------|-------|---------|
| `DSL_PARSE_xxx` | 001-006 | Malformed JSON, bad version, missing fields, unknown keys |
| `DSL_WL_xxx` | TABLE_001, FIELD_002, ROLE_003 | Table/field not whitelisted |
| `DSL_SEM_xxx` | 001-011 | Semantic issues (GROUP BY, params, aliases, MANDT) |
| `DSL_SEC_xxx` | 001-004 | Injection defense (patterns, operators, value length) |
| `DSL_GUARD_xxx` | 001-003 | Guardrail limits (max rows, join count) |
| `DSL_EXEC_xxx` | 001-006 | Runtime errors (SQL failure, timeout, fallbacks) |
| `DSL_DEPR_xxx` | 001-002 | Deprecated syntax (flat arrays) |

---

## Self-Documenting API

**GET** `/sap/zdsl/query` returns the expected JSON template:

```
GET https://<host>:<port>/sap/zdsl/query?sap-client=<client>
```

Response includes a complete valid example payload.
