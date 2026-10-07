#!/usr/bin/env bash
# Smoke test no Kind: API pelo Ingress (/users) e endpoints internos via port-forward (/healthz, /readyz, /metrics).
set -euo pipefail

NS="${NS:-estuda}"
HOST="${HOST:-estuda.local}"
BASE="${BASE:-http://localhost}"
PF_PORT="${PF_PORT:-18080}"

fail() { echo "FALHOU: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

email="smoke-$(date +%s)@example.com"
payload="{\"name\":\"Smoke Test\",\"email\":\"${email}\",\"password\":\"senha-segura\"}"

[[ "$(code -H "Host: ${HOST}" -H 'Content-Type: application/json' -d "$payload" "${BASE}/users")" == "201" ]] \
  || fail "POST /users deveria retornar 201"
ok "POST /users -> 201"

[[ "$(code -H "Host: ${HOST}" -H 'Content-Type: application/json' -d "$payload" "${BASE}/users")" == "409" ]] \
  || fail "POST /users duplicado deveria retornar 409"
ok "POST /users duplicado -> 409"

body="$(curl -s -H "Host: ${HOST}" "${BASE}/users?limit=100")"
grep -q "$email" <<<"$body" || fail "GET /users não contém o usuário criado"
grep -q '"password' <<<"$body" && fail "GET /users expôs senha"
ok "GET /users lista o usuário e não expõe senha"

# Endpoints internos: não passam pelo Ingress.
kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} -n "$NS" port-forward svc/estuda-api "${PF_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do
  [[ "$(code "http://127.0.0.1:${PF_PORT}/healthz" || true)" == "200" ]] && break
  sleep 0.5
done

[[ "$(code "http://127.0.0.1:${PF_PORT}/healthz")" == "200" ]] || fail "/healthz"
ok "/healthz -> 200"
[[ "$(code "http://127.0.0.1:${PF_PORT}/readyz")" == "200" ]] || fail "/readyz"
ok "/readyz -> 200"
curl -s "http://127.0.0.1:${PF_PORT}/metrics" | grep -q '^http_requests_total' || fail "/metrics sem http_requests_total"
ok "/metrics expõe http_requests_total"

# Métricas e health NÃO devem estar acessíveis pelo Ingress público.
[[ "$(code -H "Host: ${HOST}" "${BASE}/metrics")" != "200" ]] || fail "/metrics está exposto no Ingress"
ok "/metrics não exposto no Ingress"

echo "Smoke test OK"
