#!/usr/bin/env bash
# Deploy blue-green sem queda.
#
# Uso:    bash deploy/deploy.sh <app> <imagem:tag>
# Exemplo bash deploy/deploy.sh app-teste ghcr.io/wfmunizj/cicd-azure:3f2a1bc...
# Rollback: bash deploy/deploy.sh app-teste "$(cat /opt/lux/app-teste/previous_image)"
#
# Fluxo: sobe a cor nova ao lado da atual → espera /health → troca o upstream do Nginx →
#        reload (não derruba conexões) → drena → remove a cor antiga.
#        Health check falhou: remove a nova; a antiga nunca saiu do ar.
set -euo pipefail

APP="${1:?informe o nome do app}"
IMAGE="${2:?informe a imagem}"

BASE="/opt/lux/$APP"
UPSTREAM="/etc/nginx/lux/$APP.upstream"
PORT_BLUE="${PORT_BLUE:-18001}"
PORT_GREEN="${PORT_GREEN:-18002}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
DRAIN_SECONDS="${DRAIN_SECONDS:-10}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

if grep -q ":$PORT_BLUE;" "$UPSTREAM"; then
  OLD=blue;  NEW=green; NEW_PORT=$PORT_GREEN
else
  OLD=green; NEW=blue;  NEW_PORT=$PORT_BLUE
fi
log "Ativa: $OLD | subindo: $NEW (porta $NEW_PORT) | imagem: $IMAGE"

docker pull "$IMAGE"
docker rm -f "$APP-$NEW" >/dev/null 2>&1 || true
docker run -d --name "$APP-$NEW" --restart unless-stopped \
  --env-file "$BASE/.env" \
  -e APP_COLOR="$NEW" \
  -p "127.0.0.1:$NEW_PORT:8000" \
  "$IMAGE" >/dev/null

log "Aguardando /health (até ${HEALTH_TIMEOUT}s)..."
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
until curl -fsS --max-time 2 "http://127.0.0.1:$NEW_PORT/health" >/dev/null 2>&1; do
  if (( $(date +%s) >= deadline )); then
    log "❌ Health check falhou. Últimas linhas do container:"
    docker logs --tail 50 "$APP-$NEW" || true
    docker rm -f "$APP-$NEW" >/dev/null
    log "$OLD continua no ar. Deploy abortado."
    exit 1
  fi
  sleep 2
done
log "✅ $NEW saudável"

cp "$UPSTREAM" "$UPSTREAM.bak"
echo "server 127.0.0.1:$NEW_PORT;" > "$UPSTREAM"
if ! sudo -n /usr/sbin/nginx -t >/dev/null 2>&1; then
  log "❌ Config do Nginx inválida — restaurando"
  mv "$UPSTREAM.bak" "$UPSTREAM"
  docker rm -f "$APP-$NEW" >/dev/null
  exit 1
fi
sudo -n /usr/sbin/nginx -s reload
log "Tráfego apontado para $NEW. Drenando $OLD por ${DRAIN_SECONDS}s..."

sleep "$DRAIN_SECONDS"
docker rm -f "$APP-$OLD" >/dev/null 2>&1 || true

# Guarda a imagem anterior para rollback manual
[[ -f "$BASE/current_image" ]] && cp "$BASE/current_image" "$BASE/previous_image"
echo "$IMAGE" > "$BASE/current_image"
docker image prune -f >/dev/null

log "🚀 Deploy concluído: $APP agora em $NEW"
