#!/usr/bin/env bash
# Generates all secrets/keys for the code-interpreter stack and the matching
# LibreChat .env snippet. Run once. Re-run with --force to rotate (LibreChat
# must then be redeployed with the regenerated snippet too).
#
# Produces:
#   deploy/.env                      - consumed by docker compose (chmod 600)
#   deploy/keys/codeapi_jwt_*        - JWT signing pair (private stays with LibreChat)
#   deploy/keys/manifest_private.pem - worker->sandbox-runner execution manifest signer
#   deploy/librechat.env.snippet     - block to merge into /opt/librechat/.env
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .env && "${1:-}" != "--force" ]]; then
  echo ".env already exists; run with --force to regenerate (rotates ALL secrets)" >&2
  exit 1
fi

mkdir -p keys
chmod 700 keys
rand() { openssl rand -hex 32; }

# --- LibreChat -> CodeAPI JWT (Ed25519): LibreChat signs, codeapi verifies ---
openssl genpkey -algorithm ed25519 -out keys/codeapi_jwt_private.pem
openssl pkey -in keys/codeapi_jwt_private.pem -pubout -out keys/codeapi_jwt_public.pem
chmod 600 keys/codeapi_jwt_private.pem keys/codeapi_jwt_public.pem
JWKS_X=$(openssl pkey -pubin -in keys/codeapi_jwt_public.pem -outform DER | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
JWT_KID="librechat-codeapi-$(date +%Y-%m)"
JWT_ISSUER="librechat"
JWT_AUDIENCE="codeapi"
SINGLE_TENANT_ID="legacy"
JWKS_JSON="{\"keys\":[{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\"${JWKS_X}\",\"kid\":\"${JWT_KID}\",\"alg\":\"EdDSA\"}]}"
JWT_PRIV_B64=$(base64 -w0 keys/codeapi_jwt_private.pem)

# --- Worker -> sandbox-runner execution manifest signer (Ed25519, DER/base64) ---
openssl genpkey -algorithm ed25519 -out keys/manifest_private.pem
chmod 600 keys/manifest_private.pem
MANIFEST_PRIV_B64=$(openssl pkey -in keys/manifest_private.pem -outform DER | base64 -w0)
MANIFEST_PUB_B64=$(openssl pkey -in keys/manifest_private.pem -pubout -outform DER | base64 -w0)

REDIS_PASSWORD=$(rand)
MINIO_ACCESS_KEY="codeapi-$(openssl rand -hex 6)"
MINIO_SECRET_KEY=$(rand)
INTERNAL_SERVICE_TOKEN=$(rand)
EGRESS_GRANT_SECRET=$(rand)
BRIDGE_TOKEN=$(rand)

umask 077
cat > .env <<EOF
# generated $(date -Is) by gen-secrets.sh - do not commit
REDIS_PASSWORD=${REDIS_PASSWORD}
MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}
MINIO_SECRET_KEY=${MINIO_SECRET_KEY}
MINIO_BUCKET=codeapi-files
CODEAPI_INTERNAL_SERVICE_TOKEN=${INTERNAL_SERVICE_TOKEN}
CODEAPI_EGRESS_GRANT_SECRET=${EGRESS_GRANT_SECRET}
CODEAPI_BRIDGE_TOKEN=${BRIDGE_TOKEN}
CODEAPI_JWT_ISSUER=${JWT_ISSUER}
CODEAPI_JWT_AUDIENCE=${JWT_AUDIENCE}
CODEAPI_JWT_ALLOWED_ALGS=EdDSA
CODEAPI_JWT_KID=${JWT_KID}
CODEAPI_JWT_JWKS_JSON=${JWKS_JSON}
CODEAPI_JWT_SINGLE_TENANT_ID=${SINGLE_TENANT_ID}
CODEAPI_EXECUTION_MANIFEST_PRIVATE_KEY=${MANIFEST_PRIV_B64}
SANDBOX_EXECUTION_MANIFEST_PUBLIC_KEY=${MANIFEST_PUB_B64}
# tuning
LAUNCHER_RAM_MIB=1024
LAUNCHER_VCPUS=2
PYTHON_CONCURRENCY=1
OTHER_CONCURRENCY=4
SANDBOX_MAX_CONCURRENT_JOBS=2
EOF

cat > librechat.env.snippet <<EOF
# Code Interpreter (codeapi) - merge into /opt/librechat/.env, then
# docker compose up -d api  (from /opt/librechat) to recreate the container.
LIBRECHAT_CODE_BASEURL=http://codeapi-api:3112/v1
CODEAPI_AUTH_PROVIDER=librechat-jwt
CODEAPI_JWT_ALGORITHM=EdDSA
CODEAPI_JWT_KID=${JWT_KID}
CODEAPI_JWT_ISSUER=${JWT_ISSUER}
CODEAPI_JWT_AUDIENCE=${JWT_AUDIENCE}
CODEAPI_JWT_TTL_SECONDS=300
CODEAPI_JWT_MINT_CACHE_SECONDS=30
CODEAPI_JWT_SINGLE_TENANT_ID=${SINGLE_TENANT_ID}
CODEAPI_JWT_PRIVATE_KEY_BASE64=${JWT_PRIV_B64}
EOF

echo "Wrote .env, keys/, librechat.env.snippet (all chmod 600)."
echo "Next: ./build-image-load-and-up.sh  (after images are loaded)"
