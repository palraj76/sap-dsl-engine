# SAP JSON DSL Engine — Project Context for Claude Code

> **Read this first.** The engine is BUILT and WORKING in SAP. This is not a plan.
> Everything in `src/` is deployed and tested. Do not regenerate objects that
> already exist — read them first.

---

## What we built

A JSON-driven query engine for SAP. External applications (Java, Python, Node.js)
POST a structured JSON payload to an SAP ICF HTTP endpoint. The ABAP engine inside
SAP parses the JSON, validates it, compiles it into ABAP Open SQL, executes it, and
returns results as JSON.

The engine is **deliberately dumb** — no business logic, no hardcoded table names,
no domain knowledge. Every table, field, join and filter arrives at runtime in the
payload. All intelligence lives in the calling application.

On top of the engine we built a **26-KPI SAP GRC metric catalog** (`metrics/`) —
pure JSON payload definitions, no ABAP. Adding a KPI needs no transport.

## Why this architecture

We are a 3rd party service provider. The engine is installed in client SAP systems
via abapGit. Our application (outside their network) sends queries over HTTPS +
VPN/IP whitelist. Our competitive IP — which tables we query, what conditions we
use, what we do with the data — never touches the client SAP system. A competitor
who gets the transport gets a generic executor, not our product.

---

## Current status — v1.5+ (working in SAP)

**Verified end-to-end in a live SAP system:** single table, LEFT JOIN, INNER JOIN,
two chained JOINs, GROUP BY + COUNT, nested AND/OR filter trees, IN clause, param
binding, pagination, subqueries in IN/NOT IN, UNION (both execution paths),
`debug:true` diagnostics, and HTTP round-trip via Postman.

64 commits. ~5,400 lines of ABAP across 13 classes + 1 interface + 2 reports.

### Built since the spec was last stamped (spec is ~1 version behind the code)

These are live in `src/` but **not yet written into
`sap_json_query_engine_specification.md`** (still v1.5 / 2026-03-24):

- **UNION support** — top-level `"union": {"distinct": bool, "branches": [...]}`,
  mutually exclusive with `entity` / `sources` / `joins`
- **Two union strategies** with runtime selection: `CTE_UNION` and `INMEMORY_UNION`
  (see below). `meta.strategy_used` reports which fired
- **`output.debug: true`** → response carries a `debug` block with
  `generated_sql`, `strategy`, and per-source / per-join-target / per-union-branch
  unfiltered row counts. Built to diagnose "why did this return zero rows"
- **Hint enrichment** (`ENRICH_HINT` in the executor) — maps raw ABAP DB errors to
  plain-English causes. The `hint` field is domain `ZDSL_JSON_STR` = `STRG`
  (unbounded) specifically so long hints + full SQL are never truncated
- **Metadata pass-through** — `metricName`, `metricId`, `priority`, `description`,
  `module` accepted and echoed in the response. `metricId` fills `query_id` if absent
- **Subqueries** in `IN` / `NOT IN` filter conditions
- **`DSL_SEM_007` (MANDT-required-in-JOIN) was REMOVED** — it blocked legitimate
  GRAC queries. The spec still documents it; the code no longer enforces it.
  Do not re-add it.

If asked to update the spec, §8 (strategy), §11 (output schema) and §5.11 (output
control) are the sections that have drifted.

---

## Architecture — what each class actually does

```
ZCL_JSON_DSL_ENGINE          facade; always returns a response, never an exception
  ├─ ZCL_JSON_DSL_PARSER            (1027 lines) JSON → ZIF_JSON_DSL_TYPES=>ty_query
  ├─ ZCL_JSON_DSL_ENTITY_RESOLVER   (135)  entity name → sources/joins/fields
  ├─ ZCL_JSON_DSL_VALIDATOR         (503)  Phase A/B/C + whitelist
  ├─ ZCL_JSON_DSL_BUILDER           (654)  condition trees → SQL clauses, strategy
  └─ ZCL_JSON_DSL_EXECUTOR          (1139) dynamic SELECT, pagination, audit, debug

ZCL_JSON_DSL_CAPABILITY      (100)  runtime CTE+UNION probe, cached, config-overridable
ZCL_HTTP_DSL_HANDLER         (401)  ICF: POST=query, GET=self-documenting template
ZCL_HTTP_DSL_AUTH            (202)  ICF: client_id/secret → bearer token
ZCL_JSON_DSL_TEST            (434)  ABAP Unit
ZIF_JSON_DSL_TYPES           (204)  ALL shared types live here — start reading here
ZCX_DSL_PARSE / ZCX_DSL_SECURITY    exception classes
ZDSL_SEED_CONFIG (report)    seeds ZJSON_DSL_CONFIG + the user_access entity
ZDSL_SETUP_ICF   (report)    registers the ICF nodes programmatically
```

**`ZIF_JSON_DSL_TYPES` is the contract.** Read it before touching anything —
`ty_query`, `ty_response`, `ty_cond_node`, `ty_union`, `ty_debug_info` are all there.

### Condition trees are flattened, not nested

`ty_cond_node` has `node_id` / `parent_id` / `node_type` (`G`=group, `L`=leaf).
ABAP has no recursive structure types, so the JSON tree is flattened into a table
and rebuilt by walking parent_id. `BUILD_CONDITION_SQL` recurses over the flat table.

### The parser is a hand-rolled JSON scanner

No `/ui2/cl_json`, no external dependency — deliberate, so it runs on any release.
`SKIP_WS`, `READ_STRING`, `SKIP_BALANCED`, `JSON_EXTRACT_MEMBER` etc. are a
character-level scanner. Whitespace handling uses Unicode code points (32/9/10/13),
**not** type-C comparison — that was a real bug (see lessons below).

### Union execution — two paths, chosen at runtime

`ZCL_JSON_DSL_CAPABILITY=>IS_CTE_UNION_SUPPORTED( )` probes the DB once per work
process with a tiny `WITH +probe AS (SELECT mandt FROM t000 UNION DISTINCT ...)`
query against T000, and caches the result. Override via `ZJSON_DSL_CONFIG` key
`CTE_UNION_MODE` = `AUTO` | `FORCE_ON` | `FORCE_OFF`.

- **`CTE_UNION`** is attempted *only* when: count-only query AND
  `output.include_rows = false` AND exactly 2 branches AND the probe passed.
  Any failure falls through to in-memory — never surfaces as an error.
- **`INMEMORY_UNION`** is everything else: each branch is SELECTed separately,
  results are concatenated on the app server, and `UNION DISTINCT` dedup is done
  by building a `|`-joined value signature per row into a SORTED UNIQUE table.
  Can return rows and the count together from the same materialized set.

---

## ⚠️ Hard-won ABAP Open SQL lessons — DO NOT REGRESS THESE

Roughly 40 of the 64 commits are fixes for these. Every one cost a deploy/test
cycle in a real SAP system. Read before changing the builder or executor.

### Old vs new Open SQL syntax — the engine switches deliberately

The builder sets `needs_new_sql = abap_true` when there are **JOINs**, or a
**subquery in filters**, or a **mix of select fields + metrics** in the same query.
Otherwise it emits *old* syntax.

- **Old syntax** (`INTO` before `FROM`, no `@` escapes, **space**-separated field
  lists) is required for plain single-table dynamic SELECTs.
- **New syntax** (commas in field lists, `@` host variables) is required for JOINs,
  subqueries, and mixed field+metric selects.

Mixing them up produces syntax errors that only appear at runtime in SAP. There is
no compile-time signal. **This is the single most common source of breakage.**

**Never share one SQL fragment between an old-syntax and a new-syntax consumer.**
`BUILD_UNION` originally produced a single `select_clause`; the in-memory path
needs it space-separated (old syntax) and the CTE path needs it comma-separated
(strict/new syntax, because the outer `SELECT ... INTO @lv_count` puts the whole
statement in strict mode). Fixing one broke the other, and because the CTE failure
was caught silently it stayed hidden for ten commits while every union query
quietly degraded to the unbounded in-memory path. `ty_branch_sql` now carries
**both** forms, built from the same field list. Keep it that way.

**A fallback that is more dangerous than the thing it replaces must be loud.**
The CTE→in-memory fall-through now emits `DSL_EXEC_007` as a warning naming the
underlying failure. Silent degradation into a path that materialises every
qualifying row is how a working system dumps with `TSV_TNEW_PAGE_ALLOC_FAILED`.

### Field and alias handling

- Generated SQL uses **tilde** notation `u~BNAME`, not dot `u.BNAME`.
  `TO_SQL_FIELD` does the conversion. DSL JSON always uses dots.
- `AS` **is required** in FROM/JOIN clauses for alias resolution in dynamic Open SQL.
  It was removed once and had to be restored.
- `AS` must **not** appear in the dynamic SELECT field list — old Open SQL maps
  results by position, not by name.
- Union branch SQL **strips alias prefixes** entirely — branches are single-source.

### Types

- The dynamic result structure resolves **actual DDIC field types via RTTI**.
  Using `STRING` fails (old Open SQL cannot convert into STRING); `CHAR255` was the
  earlier workaround, RTTI lookup is the current correct answer. Wrap the DDIC
  lookup in TRY/CATCH — unknown tables/fields must not dump.
- Union branches use the **DDIC table structure + `INTO CORRESPONDING`**.
- `MIN`/`MAX`/`SUM`/`AVG` on `DATS` or `CHAR` throws a type error on some kernels.
  Return raw rows; let the caller compute.
- Cross-type field-vs-field comparison (DATS char-8 vs DEC15 timestamp) is rejected.
  Return both values; caller compares.

### Operators

- **`!=` is rejected by ABAP Open SQL on older kernels.** Every metric JSON uses
  `{"op": "NOT IN", "value": ["X"]}` instead. Universally accepted. Keep it that way.
- `IN` clause values are **comma**-separated (an earlier space-separated attempt was
  reverted).

### Clause assembly

- Only append `ORDER BY` / `GROUP BY` / `HAVING` to the SELECT when non-empty —
  an empty clause keyword is a syntax error.
- String offsets are not allowed inside function parameters — extract to a variable
  before calling `uccp()`.
- Strip BOM and any leading characters before `{` in the HTTP request body.
- Number/boolean parsing must stop at whitespace/CR/LF, or pretty-printed JSON
  breaks `limit.rows`.
- Reset the first-field flag **per row** in `SERIALIZE_ROWS`, or the output JSON
  grows stray commas.

---

## Custom tables (all exist)

| Table | Purpose |
|---|---|
| `ZJSON_DSL_WL` | field whitelist per table; supports `*` wildcard |
| `ZJSON_DSL_ENTITY` | semantic entity registry (entity_json blob) |
| `ZJSON_DSL_CONFIG` | guardrails + engine switches |
| `ZJSON_DSL_AUDIT` | query execution audit log |
| `ZJSON_DSL_ALOG` | field-level access log (client-facing transparency) |
| `ZJSON_DSL_CLNT` | client credentials (client_id → hashed secret → svc user) |

Maintenance objects (`*.tobj.xml`) exist for WL / CONFIG / ENTITY / CLNT.

### Config keys seeded by `ZDSL_SEED_CONFIG`

`MAX_ROWS_ALLOWED=10000`, `MAX_TIMEOUT_SEC=30`, `WARN_ROWS_THRESHOLD=5000`,
`WARN_JOINS_THRESHOLD=3`, `OFFSET_LARGE_TABLE_ROWS=100000`,
`TOKEN_TTL_SECONDS=3600`, `AUDIT_RETENTION_DAYS=90`, **`WHITELIST_MODE=OPEN`**.

> `WHITELIST_MODE` is seeded **OPEN** for our dev/test system — whitelist checks
> are skipped entirely. Client QA gets `STRICT` + wildcards; client production gets
> `STRICT` + explicit fields. The access log (`ZJSON_DSL_ALOG`) is written in both
> modes. Do not ship OPEN to a client production system.

Plus `CTE_UNION_MODE` (AUTO/FORCE_ON/FORCE_OFF), read by the capability class.

---

## The GRC metric catalog (`metrics/`)

26 KPIs as standalone DSL JSON files. `metrics/README.md` is the authority.

- **`base/` (13)** — single count or flat list; dashboard renders a Number card
- **`additional/` (13)** — engine returns raw counts/timestamps, the **caller**
  computes the percentage / day-delta / rollup. This is deliberate: no SQL
  expressions, no `SUM(CASE...)`, no date arithmetic in the engine
- **M17** (de-provisioning delay) is excluded — needs HR data (`PA0000`/`PA0002`)
  outside the GRAC/GRFN catalog
- **M01** is the only union metric today

### GRC data gotchas that cause false zeros

- `GRACUSERACTVL.XCONNECTOR` (key field, the user's binding system) is the join key
  to `GRACACTUSAGE` / `GRACMITUSER` — **not** `CONNECTOR` (the rule context).
  Encoded throughout; do not swap without re-verifying.
- `GRACACTUSAGE` is only populated by the `GRAC_ACTION_USAGE_SYNC` /
  `GRAC_ROLE_USAGE_SYNC` background jobs. If they never ran against the ECC/S4
  connectors, M02/M05/M08/M13 return zero even though the queries are correct.
- `GRACREVITEM`/`GRACREVCORDMAP` need a generated UAR campaign (M25, M26).
- `GRACREQRSKDET` needs requests that ran Risk Analysis (M19, M20).
- `GRACROLE.CERTIFY_DUE` is often `00000000` in test data → M14 returns zero.

**When a metric returns zero, check the data dependency before debugging the JSON.**
`"output": {"debug": true}` gives per-table unfiltered counts in one round-trip.

---

## Deployment — abapGit

All ABAP objects are stored in abapGit-compatible format. Import via abapGit,
not manual SE24/SE11 paste or transport.

| Setting | Value |
|---|---|
| FOLDER_LOGIC | PREFIX |
| STARTING_FOLDER | /src/ |
| MASTER_LANGUAGE | E |

ABAP package: **`ZDL_JSON_DSL`**

### File naming (abapGit serialization)

| Object Type | File Pattern |
|---|---|
| Package | `src/package.devc.xml` |
| Domain | `src/<name>.doma.xml` |
| Data Element | `src/<name>.dtel.xml` |
| Table / Structure | `src/<name>.tabl.xml` |
| Table Type | `src/<name>.ttyp.xml` |
| Class | `src/<name>.clas.abap` + `src/<name>.clas.xml` |
| Interface | `src/<name>.intf.abap` + `src/<name>.intf.xml` |
| Report | `src/<name>.prog.abap` + `src/<name>.prog.xml` |
| Message Class | `src/<name>.msag.xml` |
| Table Maint. Obj | `src/<name>.tobj.xml` |

### XML format rules

- Wrapped in `<abapGit version="v1.0.0" serializer="LCL_OBJECT_<type>" serializer_version="v1.0.0">`
- Root `.abapgit.xml` uses `<asx:abap>/<asx:values>/<DATA>` (no abapGit tag)
- Tables use `DD02V` (header), `DD09L` (tech settings), `DD03P_TABLE` (fields)
- Structures use `TABCLASS=INTTAB` in DD02V, no DD09L section
- Data elements `DD04V`, domains `DD01V`, table types `DD40V`
- Reference repos: github.com/palraj76/ZFI01, github.com/palraj76/Z_PHAKAMA_CLIENT_INDEPENDENT

### Workflow

Generate abapGit files in `src/` → abapGit pulls and activates → activation errors
from the abapGit log come back here → fix → re-pull.

---

## HTTP contract

```
POST /sap/zdsl/query   query execution (bearer token)
GET  /sap/zdsl/query   returns the expected JSON template (self-documenting)
POST /sap/zdsl/auth    client_id + client_secret → bearer token
```

HTTP status maps from the first error code: 400 PARSE/SEM, 403 WL_ROLE,
429 GUARD_001, 500 EXEC_001, 504 EXEC_002. A 400 still returns the full response
body with `errors` populated — never parse status alone.

---

## Documentation map

| File | What it is |
|---|---|
| `sap_json_query_engine_specification.md` | master spec, v1.5 — **~1 version behind the code** |
| `docs/dsl-json-reference.md` | caller-facing parameter reference, v1.3 |
| `sap_dsl_client_installation_guide.md` | client BASIS runbook |
| `sap_dsl_caller_integration_guide.md` | internal — our app developers |
| `proposal/technical_approach.md` | client-facing proposal (has the union/debug story) |
| `metrics/README.md` | the 26-KPI catalog + GRC data dependencies |
| `schema/dsl-query-schema.json` | JSON Schema for payload validation |

---

## Folder structure

```
src/       all abapGit ABAP objects
java/      DslClient.java — zero external dependencies
python/    dsl_client.py — uses requests
metrics/   26 GRC KPI JSON payloads (base/ + additional/)
schema/    JSON Schema + valid example
proposal/  client-facing technical approach
docs/      JSON parameter reference + HTML presentation deck
```

---

## Working agreements

- **Never break what works.** The engine is live and tested. Fixes must not regress
  the ABAP lessons above — they were each paid for with a deploy cycle.
- **abapGit format only** — never raw ABAP files or manual-paste instructions.
- **No Claude co-author line in git commits.**
- Read existing `src/` objects before generating anything; almost everything exists.
