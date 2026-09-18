# Code Interpreter (sandboxed REPL) — deployment record

Date: 2026-09-18 · Operator: opencode · Status: **deployed & verified**
Companion docs: `code-interpreter/README.md` (runbook)

This repo's live deploy files (`librechat.yaml`, `docker-compose.override.yml`,
`.env`) are **untracked/gitignored**, so this file is the committable record of
every change made to wire LibreChat to a self-hosted code-execution sandbox.
Reproducible from a fresh clone by applying the diffs below.

## 1. What was deployed

Self-hosted [LibreChat-AI/code-interpreter](https://github.com/LibreChat-AI/code-interpreter)
`v1.2.0` ("codeapi", Apache 2.0) as an 8-container compose stack in
`code-interpreter/deploy/`:

```
codeapi-api            :3112  HTTP API (JWT auth), on librechat_default network
codeapi-worker              queue worker; signs execution manifests
codeapi-sandbox             libkrun microVM (guest kernel) + NsJail, /dev/kvm
codeapi-egress              brokered egress gateway (sandbox's ONLY route out)
codeapi-toolcall            programmatic tool-call server
codeapi-files               file server (S3 via MinIO)
codeapi-redis               job queue/state
codeapi-minio               S3 storage for generated files
```

Security posture:
- Sandbox has **no network**: seccomp-level deny (verified: `connect`→EPERM,
  DNS→EAI_FAIL, 0.00 s fail); the whole stack sits on an `internal: true` docker
  network (no internet for any codeapi container either).
- Hardened mode on (`CODEAPI_HARDENED_SANDBOX_MODE=true`), unauthenticated
  `POST /v1/exec` → 401. LibreChat signs a short-lived Ed25519 JWT per request
  (`CODEAPI_AUTH_PROVIDER=librechat-jwt`); codeapi only holds the public JWKS.
- Execution-manifest keypair separates worker→runner trust.
- LibreChat v0.8.7 bundles the client (`@librechat/agents` 3.2.46); no upgrade
  needed. Stateful sessions/background exec/programmatic tools are NOT enabled
  (client lacks support; would need newer LibreChat + second `stateful` route).

### Images (supply chain)

Built on the operator Mac from `v1.2.0` (`DOCKER_DEFAULT_PLATFORM=linux/amd64`,
`COMPOSE_PROJECT_NAME=codeapi`), pushed to GHCR, pinned by digest in
`code-interpreter/deploy/docker-compose.yml` (rebuild source fallback:
`REF=3fa1f6c…` = 2026-06-22 snapshot matching the v0.8.7 client era):

```
ghcr.io/renehonig/codeapi-api@sha256:7ad6f208fa5a7cbcfef1172ee78095d4cedc2548f9bceddb7379c149f2e3b024
ghcr.io/renehonig/codeapi-service-worker@sha256:61562b0dd8f061d9badaa52431910b9ebf10daa302a1b529b4c8e0682eb4436a
ghcr.io/renehonig/codeapi-sandbox-runner@sha256:90479b533bf280770641475e1bb2283efe77b6ad25471b2bc5915d5368961d1c   (4.9 GB, baked CPython 3.14/Node/Bun)
ghcr.io/renehonig/codeapi-egress_gateway@sha256:d5b63a674b0a9b94cc4a52a97fac64324a046b0c46bd47025c95dbcfcd610170
ghcr.io/renehonig/codeapi-tool_call_server@sha256:c6324193110fbe063bb7a1f849cc3ccd7bb730a0aa9a90c4d40d7a48f671bf17
ghcr.io/renehonig/codeapi-file_server@sha256:f8fa526a57d86fd34b712fc822255f875a52476296a626ca738729bfff846f70
```

Footprint: ~0.5 GB RAM idle (+1 GB microVM per execution), 3.2 GB images.

## 2. Changes to untracked deploy files (apply manually)

### 2.1 `.env` — appended block (secret values redacted; regenerate via `code-interpreter/deploy/gen-secrets.sh`, which emits `librechat.env.snippet`)

```diff
+# Code Interpreter (codeapi)
+LIBRECHAT_CODE_BASEURL=http://codeapi-api:3112/v1
+CODEAPI_AUTH_PROVIDER=librechat-jwt
+CODEAPI_JWT_ALGORITHM=EdDSA
+CODEAPI_JWT_KID=librechat-codeapi-2026-09
+CODEAPI_JWT_ISSUER=librechat
+CODEAPI_JWT_AUDIENCE=codeapi
+CODEAPI_JWT_TTL_SECONDS=300
+CODEAPI_JWT_MINT_CACHE_SECONDS=30
+CODEAPI_JWT_SINGLE_TENANT_ID=legacy
+CODEAPI_JWT_PRIVATE_KEY_BASE64=<REDACTED: base64 of keys/codeapi_jwt_private.pem>
```

`LIBRECHAT_CODE_BASEURL` also **prevents** the client's hidden default of the
hosted `https://api.librechat.ai/v1` — code never leaves the box.

### 2.2 `docker-compose.override.yml`

```diff
 networks:
   default:
   chat-net:
     external: true
+  codeapi_default:
+    external: true
 services:
   api:
     ...
     networks:
       - default
       - chat-net
+      - codeapi_default
```

### 2.3 `librechat.yaml` — modelSpecs (line ~399)

```diff
     - name: "qwen3-8-flash-next"
       label: qwen3-8-flash-next
       default: true
       description: "qwen3-8-flash-next local!"
       webSearch: false
       fileSearch: false
-      executeCode: false
+      executeCode: true
```

Run Code / code interpreter is on by default for new conversations with that
model (per-conversation toggle still wins; other modelSpecs unchanged).

## 3. New files under `code-interpreter/` (track these)

```
README.md                    runbook: build/transfer/up/verify/tune/rollback
build/build-images.sh        build on a big machine, save tar (REF-pinned)
deploy/docker-compose.yml    hardened, digest-pinned, internal-network stack
deploy/gen-secrets.sh        generates .env + keypairs + librechat.env.snippet
```

NEVER commit (ignored via `code-interpreter/.gitignore`): `deploy/.env`,
`deploy/librechat.env.snippet`, `deploy/keys/`, `deploy/data/`, `dist/`.

## 4. Verification performed (2026-09-18)

- `GET /v1/health` → OK from inside the stack **and** from the LibreChat container.
- Unauthenticated `POST /v1/exec` → 401.
- Agent smoke test via LibreChat (executed inside the sandbox): `print(6*7)`→`42`,
  egress probe fails closed at syscall layer (`PermissionError`, DNS `gaierror`),
  exit 0, 3/3 deterministic. CPython 3.14.4.
- Known limitation (by design): stateless route ⇒ cross-call `/mnt/data`
  persistence is opportunistic only; multi-step workflows should complete
  within one execution or rely on returned attachments. No pip/npm installs.

## 5. Operations quick refs

```bash
cd code-interpreter/deploy
docker compose up -d | ps | logs -f codeapi-worker | down        # lifecycle
# LibreChat must be on network codeapi_default (see 2.2), env from 2.1
cd ../.. && docker compose up -d api                             # after .env change
```

Backups created during rollout: `.env.bak-codeinterpreter-20260918-201837`,
`docker-compose.override.yml.bak-codeinterpreter-20260918-201837`,
`librechat.yaml.bak-runcode-20260918-215844`.

Rollback = reverse of 2.1–2.3 + `docker compose down -v` in `deploy/`.
