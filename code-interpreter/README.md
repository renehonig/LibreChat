# LibreChat Code Interpreter (sandbox/REPL) — deployment kit

Self-hosted sandboxed code execution for LibreChat v0.8.7, powered by the
open-source [LibreChat-AI/code-interpreter](https://github.com/LibreChat-AI/code-interpreter)
service ("codeapi", Apache 2.0). LibreChat talks to it via
`LIBRECHAT_CODE_BASEURL` + short-lived Ed25519 JWTs minted per request.

Sandbox code runs in a **libkrun microVM** (own guest kernel, `/dev/kvm` on
this host) with **no network access**; the whole stack sits on an
`internal: true` docker network, so neither the sandbox nor the codeapi
services have internet egress.

## Layout

- `build/build-images.sh` — run on a *build machine* (~20 GB free). Produces
  `dist/codeapi-images-v1.2.0.tar` (6 images, incl. the heavy
  `codeapi-sandbox-runner` with compiled Python + bundled Node/Bun).
- `deploy/` — production compose (this server), secrets generator, keys.

## One-time install

1. **Build elsewhere** (disk on this server is the blocker, 4.2 GB free):
   ```bash
   # on the build machine
   ./build/build-images.sh                 # pinned REF=v1.2.0
   # compatibility fallback if integration tests fail against v0.8.7:
   REF=3fa1f6cd6897e60be32b09dae132ae656ccff11d ./build/build-images.sh   # 2026-06-22, LibreChat v0.8.7 era
   ```
2. **Transfer + load** (server has internet for pulls; only the *sandbox* is offline):
   ```bash
   scp dist/codeapi-images-v1.2.0.tar(.sha256) rene@server:/opt/librechat/code-interpreter/dist/
   ssh rene@server
   cd /opt/librechat/code-interpreter/deploy
   sha256sum -c ../dist/codeapi-images-v1.2.0.tar.sha256
   docker load -i ../dist/codeapi-images-v1.2.0.tar
   ```
3. **Generate secrets** (JWT keypair, execution-manifest keypair, service tokens):
   ```bash
   ./gen-secrets.sh        # writes .env, keys/, librechat.env.snippet
   ```
4. **Start the stack**:
   ```bash
   docker compose up -d
   docker compose ps     # wait for codeapi-sandbox: healthy (microVM boots its guest kernel)
   docker exec $(docker compose ps -q codeapi-api) sh -c "wget -qO- http://127.0.0.1:3112/v1/health"
   ```
5. **Wire LibreChat** (two edits, both tracked here before applying):
   - merge `librechat.env.snippet` into `/opt/librechat/.env`
   - in `/opt/librechat/docker-compose.override.yml`, join the api container to
     the codeapi network:
     ```yaml
     networks:
       default:
       chat-net:
         external: true
       codeapi_default:      # add
         external: true      # add
     services:
       api:
         ...
         networks:
           - default
           - chat-net
           - codeapi_default # add
     ```
   ```bash
   cd /opt/librechat && docker compose up -d api
   ```

## Verify

```bash
# from the LibreChat container (the only client):
docker exec LibreChat node -e \
  "fetch('http://codeapi-api:3112/v1/health').then(r=>r.text()).then(console.log)"
# expect {"status":"ok"}  (unauthenticated requests to /v1/exec must return 401)
```

In the UI: edit an AI Agent → enable **Code Interpreter** → ask it to run
`print(6*7)` in Python. Also test the shell/bash tool and a file-producing run
(write a CSV, check the attachment downloads).

Offline check (run in an agent with code interpreter):
```python
import socket
try:
    socket.create_connection(("1.1.1.1", 443), timeout=5); print("NET-LEAK")
except Exception as e:
    print("no-network OK:", e)
```

## Runtime characteristics / tuning (deploy/.env)

| knob | default | notes |
|---|---|---|
| `LAUNCHER_RAM_MIB` | 1024 | guest RAM per microVM; raise if OOMs on pandas-y work |
| `LAUNCHER_VCPUS` | 2 | host has 3 vCPUs total |
| `SANDBOX_MAX_CONCURRENT_JOBS` / `OTHER_CONCURRENCY` | 2 / 4 | lower to 1/1 if memory pressure |
| idle RAM cost | ~1.5 GB | 8 containers (redis/minio/bun services are small) |

Disk: the baked guest root lives in the images; only `data/pkgs` (empty,
baked mode) and the `minio_data` volume (generated files) grow on disk.
Watch `/` — server is at 91 %.

## Notes & caveats

- **Images are digest-pinned** in `docker-compose.yml` (pushed to
  `ghcr.io/renehonig/codeapi-*`, built from code-interpreter `v1.2.0` on the
  Mac with `DOCKER_DEFAULT_PLATFORM=linux/amd64`). Verify before deploy with
  `docker compose config`. This daemon has flaky `:latest` tag resolution —
  digest pulls (`image@sha256:...`) are the reliable path.
- **Cross-call `/mnt/data` persistence is NOT guaranteed — by design.** This is
  a single *stateless* route: every `execute_code` call runs in a fresh
  workspace; `create_file`-then-read-next-call patterns can flake (files
  survive only opportunistically until the runner's reaper, 1 h). Instruct
  agents to produce inputs+outputs within one execution, or rely on
  LibreChat-attached artifacts (generated files come back as attachments and
  are re-injected when referenced). True reusable workspaces need **Stateful
  Code Sessions** (a second `stateful`-profile codeapi route) which the
  v0.8.7 client does not support — revisit on a LibreChat upgrade.
- **No pip/npm install from the sandbox** — it has no network by design. Only
  the baked runtimes (CPython 3.14, Node, Bun + stdlib) are available. Verified
  egress is denied at the seccomp/syscall layer (connect → `EPERM`, DNS
  → `EAI_FAIL`), not via timeout. If a curated allowlist is ever needed, use
  the egress-gateway grant mechanism rather than lifting the network ban.
- LibreChat side capability defaults: `endpoints.agents.capabilities` in
  `librechat.yaml` already allows `execute_code` when unset. Pin it explicitly
  if you want to also exclude other tools.
- Stateful code sessions / background execution / programmatic tool calling:
  not enabled (single stateless route; would need a second `stateful`-profile
  deployment + newer client features).
- The hosted default `https://api.librechat.ai/v1` applies if
  `LIBRECHAT_CODE_BASEURL` is missing — the snippet always sets it, so code
  never leaves the box.
- Rollback: `docker compose down -v` in `deploy/`, remove the snippet lines +
  `codeapi_default` from LibreChat, `docker compose up -d api`.
- Versioning: `code-interpreter` v1.2.0 (2026-09-15) with LibreChat v0.8.7
  (2026-06-24). The public surface (`POST /v1/exec`, `/upload`, `/files`) is
  unchanged; if a request fails with 4xx schema errors, rebuild with the
  June-22 fallback REF above.
