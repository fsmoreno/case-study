#!/usr/bin/env bash
# Gera tráfego pelo Ingress para alimentar o dashboard (e disparar alertas em testes).
# Uso: bash scripts/traffic.sh [segundos]   (padrão: 120)
set -euo pipefail

DURATION="${1:-120}"
HOST="${HOST:-estuda.local}"
BASE="${BASE:-http://localhost}"
end=$(( $(date +%s) + DURATION ))
i=0

echo "Gerando tráfego por ${DURATION}s em ${BASE} (Host: ${HOST})..."
while [[ $(date +%s) -lt $end ]]; do
  i=$((i + 1))
  curl -s -o /dev/null -H "Host: ${HOST}" "${BASE}/users?limit=20"
  # a cada 5 iterações cria um usuário; a cada 7 repete um email (gera 409)
  if (( i % 5 == 0 )); then
    curl -s -o /dev/null -H "Host: ${HOST}" -H 'Content-Type: application/json' \
      -d "{\"name\":\"Carga $i\",\"email\":\"carga-$i-$RANDOM@example.com\",\"password\":\"senha-segura\"}" "${BASE}/users"
  fi
  if (( i % 7 == 0 )); then
    curl -s -o /dev/null -H "Host: ${HOST}" -H 'Content-Type: application/json' \
      -d '{"name":"Dup","email":"dup@example.com","password":"senha-segura"}' "${BASE}/users"
  fi
  sleep 0.2
done
echo "Concluído: ${i} ciclos."
