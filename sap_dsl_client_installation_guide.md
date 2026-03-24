# SAP JSON DSL Engine — Client Installation Guide

**For:** Client BASIS / SAP Administrator  
**Provided by:** [Your company name] (3rd party service provider)  
**Version:** 1.0 | 2026-03-24

---

## Overview

This guide covers everything the client's SAP BASIS team needs to install and configure the JSON DSL Query Engine in their SAP system. The engine is a read-only query interface that allows our application to pull data from your SAP system over HTTPS. It does not modify any SAP data, does not create any background jobs, and does not call out from SAP to any external system.

**What gets installed:**

- One ABAP transport containing all engine classes, custom tables, and ICF service registrations
- One technical service user with read-only authorizations
- One ICF service endpoint registered at `/sap/zdsl/`

**Prerequisites:**

| Requirement | Minimum |
|-------------|---------|
| SAP release | ECC 6.0 EhP7+ or S/4HANA 1909+ |
| ABAP release | 740 (for count_distinct; 702 minimum for core features) |
| ICF | Active and reachable from our service IP |
| Network | VPN tunnel or IP whitelist configured to allow inbound HTTPS from our IP(s) |
| Basis access | System Administrator access for transport import and user creation |

---

## Step 1 — Import the ABAP transport

We provide two transport files:

| File | Contains |
|------|----------|
| `K<number>.ZDL` | ABAP workbench objects (classes, structures, exception classes) |
| `R<number>.ZDL` | Table definitions, SM30 views, ICF service registrations |

**Import sequence — R first, then K:**

1. Copy both files to the transport directory: `/usr/sap/trans/cofiles/` and `/usr/sap/trans/data/`
2. In STMS, import the R transport (table definitions) first
3. Import the K transport (workbench objects) second
4. Confirm import return code 0 or 4 (warning acceptable, error is not)

> Do not import the K transport before the R transport — the classes reference the custom table structures.

---

## Step 2 — Register the ICF services

After transport import, activate the ICF services:

1. Transaction `SICF`
2. Navigate to: `default_host` → `sap` → `zdsl`
3. Right-click `zdsl` → Activate service
4. Confirm both sub-services are active:
   - `/sap/zdsl/query` — main query endpoint
   - `/sap/zdsl/auth` — token authentication endpoint

**Verify activation:**

In a browser from within your network, navigate to `https://<host>:<port>/sap/zdsl/auth`. You should receive a `405 Method Not Allowed` (it only accepts POST). A `404` means the service is not active.

---

## Step 3 — Create the technical service user

This user is the identity under which all DSL queries run. It must be a System user type (not Dialog) with no logon privileges.

**In transaction SU01:**

| Field | Value |
|-------|-------|
| User ID | `ZDSL_SVC_USER` |
| User type | System (`S`) |
| First name | DSL |
| Last name | Service User |
| Password | Generate a strong password — this is stored in our secrets manager |
| Valid from/to | Set appropriate validity window |
| Role | `ZDSL_AUDIT` |

> Never assign this user to a dialogue logon. User type `S` prevents browser/SAP GUI logon.

**Authorisation objects assigned via `ZDSL_AUDIT` role:**

| Auth object | Field | Value |
|-------------|-------|-------|
| `Z_DSL_EXEC` | `ACTVT` | `16` (Execute) |
| `S_RFC` | `RFC_TYPE` | `FUNC` |
| `S_RFC` | `RFC_NAME` | `ZDSL_*` |
| `S_TCODE` | `TCD` | — (no tcode access needed) |

> The `ZDSL_AUDIT` role grants read-only access to whitelisted tables only. It does not grant `S_TABU_DIS` (general table display) or any write authorisations.

---

## Step 4 — Register client credentials

We provide a `client_id` and `client_secret` for your installation. These are stored in the custom table `ZJSON_DSL_CLIENTS`:

1. Transaction `SM30`, view `ZV_DSL_CLIENTS`
2. Add one row:

| Field | Value |
|-------|-------|
| `CLIENT_ID` | Provided by us (e.g. `CLIENT_ACME_001`) |
| `CLIENT_SECRET_HASH` | SHA-256 hash of the secret we provide — never store plaintext |
| `SVC_USER` | `ZDSL_SVC_USER` |
| `ACTIVE` | `X` |
| `VALID_TO` | Set expiry date (recommend 1 year, then rotate) |

> We provide the secret separately via a secure channel. Store it in your secrets manager. Provide us only the confirmation that it has been entered — never send the secret back to us.

---

## Step 5 — Configure the whitelist

The whitelist controls which tables and fields the engine is permitted to query. We provide a recommended whitelist for your SAP version. You review and approve it before it goes live.

1. Transaction `SM30`, view `ZV_DSL_WL`
2. Import entries from the CSV we provide, or enter manually
3. Minimum required entries for our standard use case:

| Table | Allowed Fields | Role |
|-------|---------------|------|
| `USR02` | BNAME, USTYP, GLTGV, GLTGB, TRDAT, MANDT | ZDSL_AUDIT |
| `AGR_USERS` | UNAME, AGR_NAME, FROM_DAT, TO_DAT, MANDT | ZDSL_AUDIT |
| `AGR_1251` | ROLE, OBJECT, AUTH, FIELD, LFROM, LTO, MANDT | ZDSL_AUDIT |

> You have full visibility and control over this whitelist. If we need to query additional tables, we request your approval and you add the entries. The engine cannot query any table not on this list.

---

## Step 6 — Configure performance guardrails

1. Transaction `SM30`, view `ZV_DSL_CONFIG`
2. Review and adjust default values:

| Config key | Default | Description |
|------------|---------|-------------|
| `MAX_ROWS_ALLOWED` | `10000` | Hard cap — we cannot request more rows than this per call |
| `MAX_TIMEOUT_SEC` | `30` | Query execution time limit in seconds |
| `WARN_ROWS_THRESHOLD` | `5000` | Row count above which a warning is logged |
| `WARN_JOINS_THRESHOLD` | `3` | Join count above which a warning is logged |
| `OFFSET_LARGE_TABLE_ROWS` | `100000` | Threshold for offset pagination performance warning |
| `TOKEN_TTL_SECONDS` | `3600` | Bearer token validity period |
| `AUDIT_RETENTION_DAYS` | `90` | Audit log retention |

> These are your controls. You can tighten any of these values at any time without involving us.

---

## Step 7 — Network configuration

Our service IPs that need inbound access to your SAP ICF port:

| IP | Purpose |
|----|---------|
| Provided by us | Production service |
| Provided by us | Failover / DR service |

**Firewall rule required:**

```
Source:      <our IPs>
Destination: <SAP host>:<ICF port> (typically 8000 or 443)
Protocol:    TCP/HTTPS
Direction:   Inbound only
```

There is no outbound rule required — SAP never initiates a connection to our network.

---

## Step 8 — Verify end-to-end

Once all steps are complete, we run a verification test from our end. We will send one test query and confirm receipt of data. You can monitor the call in:

- **ICF log:** Transaction `SMICM` → Goto → Trace file
- **Engine audit log:** Transaction `SM30` → `ZV_DSL_AUDIT` (Flex Mode entries only)
- **Standard logs:** Transaction `SLG1` with object `ZDSL`

Expected first test result: one row from `USR02` for a known user, returned in under 5 seconds.

---

## Ongoing operations

**Credential rotation:**

We recommend rotating the `client_secret` annually. Process: we generate a new secret, you update `ZJSON_DSL_CLIENTS`, we update our secrets manager, and both sides verify. Zero downtime — the old token stays valid until it expires (max `TOKEN_TTL_SECONDS`).

**Whitelist changes:**

Any request to add new tables or fields comes from us in writing. You review and approve before making any change. Whitelist changes require a transport in production — direct SM30 edits are not permitted.

**Uninstallation:**

To remove the engine completely:
1. Deactivate ICF services in `SICF`
2. Lock and delete `ZDSL_SVC_USER` in `SU01`
3. Delete custom table entries via SM30
4. Reverse-import or delete the transport objects via SE80

All SAP data and configuration remains untouched. The engine only reads — it leaves no persistent state in SAP beyond the custom tables it owns.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `401 Unauthorized` | Token expired or `ZJSON_DSL_CLIENTS` entry inactive |
| `403 Forbidden` | `ZDSL_SVC_USER` missing `ZDSL_AUDIT` role or `Z_DSL_EXEC` auth object |
| `404 Not Found` | ICF service not activated in `SICF` |
| `500 Internal Server Error` | Check `SLG1` with object `ZDSL` for ABAP dump details |
| `504 Gateway Timeout` | Query exceeded `MAX_TIMEOUT_SEC` — increase guardrail or raise with us to optimise the query |
| Connection refused | Firewall rule missing or VPN tunnel down |

---

**Contact:** For installation support, contact [your support email].  
**Transport provided separately** via secure file transfer.

---

*End of Client Installation Guide — v1.0 (2026-03-24)*
