# SAP JSON DSL Engine — Project Context for Claude Code


## What we are building

A JSON-driven query engine for SAP. External applications (Java, Python, Node.js)
send a structured JSON payload to an SAP ICF HTTP endpoint. The ABAP engine inside
SAP parses the JSON, validates it, compiles it into ABAP Open SQL, executes it, and
returns results as JSON. The engine is deliberately dumb — no business logic, no
hardcoded table names. All intelligence lives in the calling application.


## Why this architecture

We are a 3rd party service provider. The engine is installed in client SAP systems
via ABAP transport. Our application (outside their network) sends queries over
HTTPS + VPN/IP whitelist. Our competitive IP — which tables we query, what conditions
we use, what we do with the data — never touches the client SAP system. A competitor
who gets the transport gets a generic executor, not our product.


## Full specification

See: sap_json_query_engine_specification.md  (v1.4)
See: sap_dsl_client_installation_guide.md    (v1.0)
See: sap_dsl_caller_integration_guide.md     (v1.0)


## Tech stack

- SAP side: ABAP (ECC 6.0+ or S/4HANA), Open SQL / AMDP, ICF HTTP handler
- Caller side: Java (primary), Python, Node.js — all call via HTTPS POST
- Auth: bearer token, mapped to SAP technical service user ZDSL_SVC_USER
- No middleware layer — raw JSON from SAP goes directly into our Java pipeline


## ABAP package

ZDL_JSON_DSL — all objects live here


## Deployment method — abapGit

All ABAP objects are stored in **abapGit-compatible format** in this repository.
Import into SAP is done via abapGit (not manual SE24/SE11 paste or transport).

### abapGit settings

| Setting          | Value    |
|------------------|----------|
| FOLDER_LOGIC     | PREFIX   |
| STARTING_FOLDER  | /src/    |
| MASTER_LANGUAGE  | E        |

### File naming conventions (abapGit serialization)

| Object Type       | File Pattern                                        |
|-------------------|-----------------------------------------------------|
| Package           | `src/package.devc.xml`                              |
| Domain            | `src/<name>.doma.xml`                               |
| Data Element      | `src/<name>.dtel.xml`                               |
| Table / Structure | `src/<name>.tabl.xml`                               |
| Table Type        | `src/<name>.ttyp.xml`                               |
| Class             | `src/<name>.clas.abap` + `src/<name>.clas.xml`      |
| Class locals      | `src/<name>.clas.locals_def.abap` (if needed)       |
| Interface         | `src/<name>.intf.abap` + `src/<name>.intf.xml`      |
| Message Class     | `src/<name>.msag.xml`                               |
| Lock Object       | `src/<name>.enqu.xml`                               |
| Table Maint. Obj  | `src/<name>.tobj.xml`                               |
| Function Group    | `src/<name>.fugr.*`                                 |
| Transaction       | `src/<name>.tran.xml`                               |
| Auth Object       | `src/<name>.suso.xml`                               |

### XML format rules

- All XML files wrapped in `<abapGit version="v1.0.0" serializer="LCL_OBJECT_<type>" serializer_version="v1.0.0">`
- Root `.abapgit.xml` uses `<asx:abap>/<asx:values>/<DATA>` wrapper (no abapGit tag)
- Class `.clas.abap` files contain plain ABAP source (CLASS DEFINITION + IMPLEMENTATION)
- Table `.tabl.xml` files use `DD02V` (header), `DD09L` (tech settings), `DD03P_TABLE` (fields)
- Structures use `TABCLASS=INTTAB` in DD02V, no DD09L section
- Data elements use `DD04V`, domains use `DD01V`
- Table types use `DD40V`
- Reference repos for format: github.com/palraj76/ZFI01, github.com/palraj76/Z_PHAKAMA_CLIENT_INDEPENDENT

### Import workflow

1. Claude generates all ABAP objects as abapGit files in `src/`
2. Point abapGit in SAP to this repo (or private fork)
3. abapGit pulls and activates — handles dependency order automatically
4. Activation errors from abapGit log → feed back to Claude → fix and re-pull


## Key ABAP classes to build (in order)

1. ZCL_JSON_DSL_PARSER         — JSON string → ZST_DSL_QUERY structure
2. ZCL_JSON_DSL_ENTITY_RESOLVER — entity name → expands sources/joins/fields
3. ZCL_JSON_DSL_VALIDATOR       — Phase A (structural) + B (semantic) + C (injection)
4. ZCL_JSON_DSL_BUILDER         — condition trees → SQL string, strategy selection
5. ZCL_JSON_DSL_EXECUTOR        — execute SQL, pagination, response assembly
6. ZCL_HTTP_DSL_HANDLER         — ICF HTTP handler: receive POST, call engine
7. ZCL_HTTP_DSL_AUTH            — ICF auth handler: issue bearer token
8. ZCL_JSON_DSL_ENGINE          — facade wiring all above, always returns response


## Custom tables needed

- ZJSON_DSL_WL       — field whitelist per table
- ZJSON_DSL_ENTITY   — semantic entity registry
- ZJSON_DSL_CONFIG   — guardrails (MAX_ROWS_ALLOWED=10000, MAX_TIMEOUT_SEC=30)
- ZJSON_DSL_AUDIT    — Flex Mode execution audit log
- ZJSON_DSL_CLIENTS  — client credentials (client_id → hashed secret → svc user)


## Supporting DDIC objects needed

- Domains: ZDSL_CONFIG_KEY, ZDSL_CONFIG_VAL, ZDSL_ERROR_CODE, ZDSL_SEVERITY, etc.
- Data elements: for each table field that needs a custom type
- Table types: ZTT_DSL_ERROR (table of ZST_DSL_ERROR)
- Structures: ZST_DSL_QUERY, ZST_DSL_RESPONSE, ZST_DSL_ERROR, and sub-structures
- Exception classes: ZCX_DSL_PARSE, ZCX_DSL_SECURITY
- Message class: ZDSL (for all DSL_xxx error messages)
- Table maintenance generators: for ZJSON_DSL_WL, ZJSON_DSL_CONFIG, ZJSON_DSL_CLIENTS, ZJSON_DSL_ENTITY


## Error codes

Full taxonomy in spec §10. Pattern: DSL_PARSE_xxx, DSL_SEM_xxx, DSL_SEC_xxx,
DSL_WL_xxx, DSL_GUARD_xxx, DSL_EXEC_xxx, DSL_DEPR_xxx


## Implementation phases

### Phase 1 — Infrastructure (DDIC + tables)
- .abapgit.xml, package.devc.xml
- Domains, data elements
- Structures (ZST_DSL_QUERY, ZST_DSL_RESPONSE, ZST_DSL_ERROR + sub-structures)
- Table types (ZTT_DSL_ERROR)
- Custom tables (ZJSON_DSL_WL, ZJSON_DSL_ENTITY, ZJSON_DSL_CONFIG, ZJSON_DSL_AUDIT, ZJSON_DSL_CLIENTS)
- Message class ZDSL
- Exception classes (ZCX_DSL_PARSE, ZCX_DSL_SECURITY)

### Phase 2 — Core engine classes
- ZCL_JSON_DSL_PARSER
- ZCL_JSON_DSL_ENTITY_RESOLVER
- ZCL_JSON_DSL_VALIDATOR
- ZCL_JSON_DSL_BUILDER
- ZCL_JSON_DSL_EXECUTOR

### Phase 3 — HTTP layer
- ZCL_HTTP_DSL_AUTH
- ZCL_HTTP_DSL_HANDLER
- ZCL_JSON_DSL_ENGINE (facade)

### Phase 4 — Testing
- ZCL_JSON_DSL_TEST (unit tests covering all DSL_xxx error codes)


## Current status

Specification complete (v1.4). Implementation not started.
Start from Phase 1 (infrastructure).


## Folder structure

src/               — All abapGit ABAP objects (classes, tables, structures, etc.)
java/              — Java caller integration code
docs/              — All specification documents (if moved from root)
