# SAP JSON DSL Engine — Caller Integration Guide

**For:** Our application developers (Java, Python, Node.js)  
**Audience:** Internal — do not share with clients  
**Version:** 1.0 | 2026-03-24

---

## Overview

This guide explains how our application services call the SAP JSON DSL Engine installed in a client's SAP system. The engine is a dumb executor — it runs whatever query JSON we send it. All business logic, table selection, field mapping, and data processing stays in our code. The client never sees our query definitions.

**The golden rule:** The DSL JSON is assembled in our code, signed in memory, sent over HTTPS, and discarded after the response arrives. It never persists anywhere accessible to the client or a competitor.

---

## 1. Client registry

We maintain a client registry in our application. Each entry represents one client SAP system installation. The engine path `/sap/zdsl/query` is the same for every client — only the host differs.

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

**Key points:**
- `client_id` is our identifier — SAP does not use it for access control, only for our correlation logging
- `sap_installation_number` + `sap_sid` help us identify the exact SAP system during support calls with the client's BASIS team
- One entry per SAP system. If a client has DEV, QA, and PRD systems, each gets its own entry with its own credentials
- SAP does not route or behave differently based on which client calls — isolation is entirely in our application layer and in each client's own whitelist/config tables

---

## 2. Authentication

### 2.1 Token flow

Tokens are valid for 1 hour (configurable per client in `ZJSON_DSL_CONFIG`). Cache them. Refresh proactively at 50 minutes to avoid expiry mid-operation.

```python
# Python example — token manager
import requests
import time

_token_cache = {}

def get_token(client_id: str, endpoint: str, secret: str) -> str:
    cached = _token_cache.get(client_id)
    if cached and cached['expires_at'] > time.time() + 600:
        return cached['token']

    response = requests.post(
        f"{endpoint}/auth",
        json={"client_id": client_id, "client_secret": secret},
        verify=True,
        timeout=10
    )
    response.raise_for_status()
    token_data = response.json()

    _token_cache[client_id] = {
        'token': token_data['access_token'],
        'expires_at': time.time() + token_data['expires_in']
    }
    return token_data['access_token']
```

```javascript
// Node.js token manager
const tokenCache = new Map();

async function getToken(clientId, endpoint, secret) {
  const cached = tokenCache.get(clientId);
  if (cached && cached.expiresAt > Date.now() + 600_000) {
    return cached.token;
  }
  const res = await fetch(`${endpoint}/auth`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_id: clientId, client_secret: secret })
  });
  const data = await res.json();
  tokenCache.set(clientId, {
    token: data.access_token,
    expiresAt: Date.now() + data.expires_in * 1000
  });
  return data.access_token;
}
```

### 2.2 On 401 response

Always refresh the token once on a `401` and retry the request. If a second `401` occurs, raise an alert — the credentials may have been rotated.

---

## 3. Sending a query

### 3.1 Core call pattern

Every call follows this pattern:
1. Resolve client config from our registry
2. Fetch token (from cache or refresh)
3. Assemble DSL JSON payload in our code
4. POST to endpoint with required headers
5. Handle response (check `errors` array, not just HTTP status)
6. Extract `data.rows` and pass to our processing pipeline

### 3.2 Python

```python
import requests
import uuid

def query_sap(client_id: str, payload: dict) -> dict:
    client = get_client_config(client_id)
    secret = resolve_secret(client['client_secret_ref'])
    token = get_token(client_id, client['sap_endpoint'], secret)

    response = requests.post(
        f"{client['sap_endpoint']}/query",
        json=payload,
        headers={
            'Authorization': f'Bearer {token}',
            'X-DSL-Client-ID': client_id,
            'X-DSL-Request-ID': str(uuid.uuid4()),
            'Content-Type': 'application/json'
        },
        verify=client.get('tls_cert_ref') or True,
        timeout=35  # must exceed MAX_TIMEOUT_SEC (30) to get proper SAP 504
    )

    if response.status_code == 401:
        # token expired mid-session — refresh once and retry
        invalidate_token(client_id)
        return query_sap(client_id, payload)

    response.raise_for_status()
    result = response.json()

    if result.get('errors'):
        raise DSLQueryError(result['errors'])

    return result
```

### 3.3 Node.js

```javascript
async function querySAP(clientId, payload) {
  const client = getClientConfig(clientId);
  const secret = await resolveSecret(client.clientSecretRef);
  const token = await getToken(clientId, client.sapEndpoint, secret);

  const requestId = crypto.randomUUID();

  const res = await fetch(`${client.sapEndpoint}/query`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`,
      'X-DSL-Client-ID': clientId,
      'X-DSL-Request-ID': requestId
    },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(35_000)
  });

  if (res.status === 401) {
    invalidateToken(clientId);
    return querySAP(clientId, payload);  // retry once
  }

  if (!res.ok) {
    throw new Error(`SAP DSL HTTP error: ${res.status}`);
  }

  const result = await res.json();

  if (result.errors?.length) {
    throw new DSLQueryError(result.errors);
  }

  return result;
}
```

### 3.4 Java

```java
public DslResponse querySAP(String clientId, Object payload) throws Exception {
    ClientConfig client = getClientConfig(clientId);
    String secret = secretsManager.resolve(client.getClientSecretRef());
    String token = tokenManager.getToken(clientId, client.getSapEndpoint(), secret);

    String payloadJson = objectMapper.writeValueAsString(payload);
    String requestId = UUID.randomUUID().toString();

    HttpRequest request = HttpRequest.newBuilder()
        .uri(URI.create(client.getSapEndpoint() + "/query"))
        .header("Content-Type", "application/json")
        .header("Authorization", "Bearer " + token)
        .header("X-DSL-Client-ID", clientId)
        .header("X-DSL-Request-ID", requestId)
        .POST(HttpRequest.BodyPublishers.ofString(payloadJson))
        .timeout(Duration.ofSeconds(35))
        .build();

    HttpResponse<String> response = httpClient.send(request,
        HttpResponse.BodyHandlers.ofString());

    if (response.statusCode() == 401) {
        tokenManager.invalidate(clientId);
        return querySAP(clientId, payload);  // retry once
    }

    if (response.statusCode() >= 400) {
        throw new RuntimeException("SAP DSL error: " + response.statusCode());
    }

    DslResponse result = objectMapper.readValue(response.body(), DslResponse.class);

    if (!result.getErrors().isEmpty()) {
        throw new DSLQueryException(result.getErrors());
    }

    return result;
}
```

---

## 4. Assembling the DSL payload

### 4.1 Never accept raw JSON from users

Our application builds the DSL JSON internally. End users may supply filter values (a date, a user ID) but never the query structure itself. Always construct the payload programmatically.

```python
# CORRECT — we control the structure
def build_user_audit_query(as_of_date: str, user_types: list) -> dict:
    return {
        "version": "1.3",
        "query_id": f"Q-{generate_id()}",
        "sources": [{"table": "USR02", "alias": "u"}],
        "joins": [{
            "type": "left",
            "target": {"table": "AGR_USERS", "alias": "ru"},
            "on": {
                "logic": "AND",
                "conditions": [
                    {"left": "u.BNAME", "op": "=", "right": "ru.UNAME"},
                    {"left": "u.MANDT", "op": "=", "right": "ru.MANDT"}
                ]
            }
        }],
        "select": [
            {"field": "u.BNAME", "alias": "user", "type": "STRING"},
            {"field": "ru.AGR_NAME", "alias": "role", "type": "STRING"}
        ],
        "filters": {
            "logic": "AND",
            "conditions": [
                {"field": "u.USTYP", "op": "IN", "value": user_types},
                {"field": "ru.TO_DAT", "op": ">=", "param": "asOfDate"}
            ]
        },
        "params": {"asOfDate": as_of_date},
        "order_by": [{"field": "u.BNAME", "direction": "asc"}],
        "limit": {"rows": 5000, "page_size": 500}
    }

# WRONG — never do this
def build_query_from_user_input(raw_json_from_user: str) -> dict:
    return json.loads(raw_json_from_user)  # ← NEVER
```

### 4.2 Pagination

```python
def fetch_all_pages(client_id: str, base_payload: dict) -> list:
    all_rows = []
    page_token = None

    while True:
        payload = {**base_payload}
        if page_token:
            payload['limit'] = {**payload.get('limit', {}), 'page_token': page_token}

        result = query_sap(client_id, payload)
        all_rows.extend(result['data']['rows'])

        if not result['meta']['has_more']:
            break

        page_token = result['meta']['next_page_token']

    return all_rows
```

> Always set `order_by` when using pagination. Without a deterministic sort, pages may overlap or miss rows.

---

## 5. Response handling

### 5.0 Raw JSON — no transformation needed

SAP returns the response body as a JSON string. Our Java application receives it directly and feeds it into the processing pipeline. No middleware transformation, no schema mapping, no ETL step is needed between SAP and our application. Parse the JSON, extract `data.rows`, and pass the rows to the relevant service class.

```java
// Minimal Java response handling
String responseBody = httpResponse.body();
DslResponse dslResponse = objectMapper.readValue(responseBody, DslResponse.class);
List<Map<String, Object>> rows = dslResponse.getData().getRows();
// pass rows directly to your domain processing class
myDomainService.process(rows);
```

### 5.1 Full response structure

```python
result = query_sap(client_id, payload)

rows         = result['data']['rows']        # list of dicts, keyed by field alias
aggregates   = result['data']['aggregates']  # list of {alias, type, value}
row_count    = result['meta']['row_count']   # rows in this page
total_count  = result['meta']['total_count'] # total (if include_summary: true)
has_more     = result['meta']['has_more']
next_token   = result['meta']['next_page_token']
exec_ms      = result['meta']['execution_time_ms']
strategy     = result['meta']['strategy_used']  # OPEN_SQL / NATIVE_SQL / AMDP
warnings     = result['warnings']   # list of {code, severity, message}
errors       = result['errors']     # list — non-empty means query failed
```

### 5.2 Error handling

```python
from enum import Enum

class DSLErrorCategory(Enum):
    PARSE    = "DSL_PARSE"
    WHITELIST = "DSL_WL"
    SEMANTIC = "DSL_SEM"
    SECURITY = "DSL_SEC"
    GUARDRAIL = "DSL_GUARD"
    EXECUTION = "DSL_EXEC"

def handle_dsl_errors(errors: list):
    for err in errors:
        code = err['code']
        if code.startswith('DSL_WL_ROLE'):
            raise PermissionError(f"SAP access denied: {err['message']}")
        elif code.startswith('DSL_GUARD_001'):
            raise ValueError(f"Query exceeds client row limit: {err['hint']}")
        elif code.startswith('DSL_EXEC_001'):
            raise RuntimeError(f"SAP execution error: {err['message']}")
        elif code.startswith('DSL_SEC'):
            # This should never happen if we build payloads correctly
            alert_security_team(err)
            raise SecurityError(f"Injection defense triggered: {err['message']}")
        else:
            raise DSLQueryError(f"[{code}] {err['message']} — {err.get('hint', '')}")
```

### 5.3 Warnings to monitor

| Code | Action |
|------|--------|
| `DSL_EXEC_003` | `count_distinct` fallback active — result is correct but slower |
| `DSL_EXEC_005` | Offset pagination on large table — consider switching to AMDP or reducing page size |
| `DSL_GUARD_002` | Approaching row limit — review if full result set is needed |
| `DSL_GUARD_003` | Too many joins — review query for performance |

Log all warnings. Alert on `DSL_EXEC_005` and `DSL_GUARD_002` recurring on the same client.

---

## 6. Security rules — mandatory

These apply to every developer working on SAP DSL integration:

1. **Never log the full DSL JSON payload** — it reveals our table and field strategy. Log only `query_id`, `client_id`, `X-DSL-Request-ID`, HTTP status, and execution time.
2. **Never store the DSL payload** in a database, message queue, or cache in plaintext. If you must persist it for retry, encrypt it.
3. **Never send credentials in URL parameters** — always in headers.
4. **Use the secrets manager** — no credentials in code, config files, environment variables, or CI/CD pipelines.
5. **Validate user inputs** before they become filter values. A user-supplied date must be validated as a date. A user-supplied ID must be validated as alphanumeric. Never allow arbitrary strings to flow into `value` fields.
6. **Set timeouts** — always 35 seconds (5 seconds above SAP's `MAX_TIMEOUT_SEC` default of 30) so we get a proper `504` from SAP rather than a hung connection.

---

## 7. Logging and tracing

Every SAP DSL call must be logged with:

```json
{
  "timestamp": "2026-03-24T10:30:00Z",
  "client_id": "CLIENT_ACME_001",
  "request_id": "req-abc-123",
  "query_id": "Q-20260324-0001",
  "http_status": 200,
  "execution_ms": 94,
  "row_count": 50,
  "strategy_used": "OPEN_SQL",
  "warnings": [],
  "errors": []
}
```

Do not log: table names, field names, filter values, or the DSL JSON body.

The `X-DSL-Request-ID` header ties our log entry to the SAP ICF log entry on the client's system. When debugging a production issue with the client's BASIS team, this ID is the correlation key.

---

## 8. Onboarding a new client

When a new client installation is ready:

1. Receive confirmation from client that Steps 1–7 of the Installation Guide are complete
2. Add client entry to our client registry with their endpoint URL
3. Retrieve the shared secret from our secure delivery channel
4. Store it in the secrets manager under the appropriate key
5. Run the verification test: `scripts/verify_client.py --client-id CLIENT_XXX`
6. Confirm one successful query result in our logs
7. Mark client as `active: true` in the registry

---

*End of Caller Integration Guide — v1.0 (2026-03-24)*  
*Internal document — do not distribute to clients or third parties.*
