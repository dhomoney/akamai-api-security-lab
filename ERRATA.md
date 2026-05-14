# ERRATA — Noname Documentation Bugs

## 1. `POST /api/v3/connectors/1` — malformed curl example

**Source:** `docs.nonamesecurity.com/docs/traffic-source-integrations-using-management-api`
**Section:** "For example, to create an AWS manual integration integration using curl"

The inline curl snippet contains a JSON syntax error — the closing brace of `settings` is followed by `"hostHeaders"` at an incorrect nesting level, making the JSON invalid:

```json
// As shown in docs (broken):
{
  "alias": "AWS 1",
  "integrationMethod": "MANUAL",
  "settings": {
    "engineId": "<engine ID>",
    },            // <-- stray brace closes settings prematurely
    "hostHeaders": [...]
}
```

The table in the same page (Cloud Providers / Connectors) shows the correct structure:

```json
{
  "alias": "<profile name>",
  "integrationMethod": "MANUAL",
  "settings": {
    "engineId": "<ID>",
    "deploymentMethod": "CLOUDFORMATION",
    "deploymentScope": "CENTRALIZED"
  },
  "hostHeaders": ["x-forwarded-host"]
}
```

**Impact:** Following the curl snippet verbatim omits the required `settings.deploymentMethod` and `settings.deploymentScope` fields, causing the API to return HTTP 500 Internal Server Error with body `{"message":"Internal server error","statusCode":500}`. The fix is to use the table's JSON schema instead.

**Confirmed against:** Noname v3.64 (`product_version: '3.64'`), captured 2026-04-24.

---

## 2. `GET /api/v3/connectors` — not a valid REST list endpoint

**Source:** `docs.nonamesecurity.com/docs/connectors`

The docs imply connectors can be listed. In practice, `GET /api/v3/connectors` returns HTTP 200 with an HTML SPA page body, not a JSON array. There is no machine-readable list endpoint for connectors (unlike `GET /api/v3/sources` which returns a proper JSON array).

**Impact:** Any automation that tries to check for an existing connector before creating one (idempotency guard) cannot use this endpoint.

**Workaround:** `GET /api/v3/sources` returns a proper JSON array that includes both traffic sources *and* connectors. Connectors appear with `"type": "CONNECTOR"` and `"integrationMethod": "MANUAL"`. Use this endpoint for idempotency checks before calling `POST /api/v3/connectors/1`.

**Deletion:** `DELETE /api/v3/connectors/{id}` (using the UUID from the `GET /api/v3/sources` response) returns HTTP 200 on success. `DELETE /api/v3/sources/{id}` does NOT work for connectors (returns HTTP 500).

**Confirmed against:** Noname v3.64, captured 2026-05-13.
