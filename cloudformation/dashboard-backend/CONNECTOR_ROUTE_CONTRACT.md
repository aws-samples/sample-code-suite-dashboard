# Connector Route Contract (v1, read-only)

Maps the existing dashboard API to a set of routes that an **Amazon Quick OpenAPI
action connector** can consume. This is the design contract the connector
Lambda handlers and `openapi.json` are built against.

## Why a separate route set

The existing routes (`GET /stats`, `/accounts`, `/pipelines`) use
`AuthorizationType: AWS_IAM` (SigV4) and return arrays / deeply nested objects.
Amazon Quick's OpenAPI connector:

- does **not** support SigV4 — only OAuth 2.0, API key, or none
- does **not** support array-typed schemas or deep nesting
- requires `application/json`, `operationId`, and descriptions per operation

So we add a **parallel** `/connector/*` route set with **OAuth2 (Cognito) JWT
auth** and **flat, paginated** responses. The existing `AWS_IAM` routes stay
untouched for the local Vite/React UI.

## Authentication

- **Model:** OAuth 2.0 client credentials (machine-to-machine).
- **Issuer:** Cognito user pool domain, token endpoint
  `https://<domain>.auth.<region>.amazoncognito.com/oauth2/token`.
- **Connector sends:** `Authorization: Bearer <access_token>`.
- **API Gateway:** HTTP API `JWT` authorizer, issuer = the Cognito user pool,
  audience = the app client ID; a read scope is required per route.
- **Scope:** `pipeline-dashboard/read`.

## Route map

| Connector op | Method + path | Auth | Replaces | Input | Response |
|---|---|---|---|---|---|
| `getStats` | `GET /connector/stats` | JWT (read) | `GET /stats` | none | flat stats object |
| `getAccounts` | `GET /connector/accounts` | JWT (read) | `GET /accounts` | `pageSize`, `nextToken` | `{ items:[...], nextToken }` |
| `getPipelines` | `GET /connector/pipelines` | JWT (read) | `GET /pipelines` (list) | `accountId?`, `status?`, `pageSize?`, `nextToken?` | `{ items:[...flat summaries], nextToken, errorCount }` |
| `getPipeline` | `GET /connector/pipelines/{accountId}/{pipelineName}` | JWT (read) | `GET /pipelines` (one row detail) | path params | one flat pipeline detail incl. bounded stages/history |

`getPipelines` returns **flat summaries** (no nested `stages`/`history`).
Per-pipeline detail (stages, history) is fetched on demand via `getPipeline`.
This keeps list responses within the connector's schema constraints and caps
payload size.

## Response schemas (flat)

### getStats
```json
{
  "total": 12,
  "running": 2,
  "failed24h": 1,
  "successRate": 92,
  "runs24h": 24
}
```

### getAccounts
```json
{
  "items": [
    { "id": "aws-123456789012", "alias": "aws", "region": "us-west-2" }
  ],
  "nextToken": ""
}
```
`items` is an array of flat objects (single level). `nextToken` is an opaque
string; empty string means no more pages.

### getPipelines (flat summary list)
```json
{
  "items": [
    {
      "accountId": "aws-123456789012",
      "accountAlias": "aws",
      "region": "us-west-2",
      "name": "sample-node-api",
      "repository": "sample-node-api",
      "branch": "main",
      "triggerType": "BranchMerge",
      "status": "Succeeded",
      "version": "abc12345",
      "lastRunStart": 1789990000000,
      "durationMs": 45000,
      "stageCount": 4,
      "logsUrl": "https://console.aws.amazon.com/codesuite/..."
    }
  ],
  "nextToken": "",
  "errorCount": 0
}
```
Each item is one level deep. `stageCount` replaces the nested `stages` array
in the list view. `errorCount` is a number, not a nested error array; details
stay in Lambda logs.

### getPipeline (single detail)
```json
{
  "accountId": "aws-123456789012",
  "accountAlias": "aws",
  "region": "us-west-2",
  "name": "sample-node-api",
  "repository": "sample-node-api",
  "branch": "main",
  "triggerType": "BranchMerge",
  "status": "Succeeded",
  "version": "abc12345",
  "lastRunStart": 1789990000000,
  "durationMs": 45000,
  "logsUrl": "https://console.aws.amazon.com/codesuite/...",
  "stages": [
    { "name": "Source", "status": "Succeeded", "url": "https://..." }
  ],
  "history": [
    { "status": "Succeeded", "durationMs": 45000, "startTime": 1789990000000 }
  ]
}
```
`stages` and `history` are arrays of flat objects (one level deep), which the
connector tolerates, unlike the original list-of-pipelines-of-arrays shape.

## Pagination

- `pageSize`: integer, default 25, max 100.
- `nextToken`: opaque base64 of `{ "o": <offset> }`. Empty/absent = first page.
- Response `nextToken` empty string = last page.
- Offset-based paging over the already-assembled result set. Acceptable for v1;
  can move to native CodePipeline pagination tokens later if needed.

## Filtering (getPipelines)

- `accountId` — exact match on the `aws-<id>` account id.
- `status` — one of `Succeeded|InProgress|Failed|Stopped`.
- Filters apply before pagination.

## Errors

Flat error object, HTTP status set accordingly:
```json
{ "error": "invalid_next_token" }
```
- `400 invalid_next_token`, `400 invalid_page_size`, `400 invalid_status`
- `404 pipeline_not_found` (getPipeline)
- `500 internal_error` with `requestId`

## Out of scope for v1

- Chat (`POST /chat`) — deferred; would need JWT-authorized POST route.
- Writes — none; connector is read-only (`x-amzn-operation-type: read`).
- QuickSight dataset — not used in the connector-only architecture.
