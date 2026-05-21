#!/bin/sh
# Wait for the edge-node + caddy to produce everything the relay needs,
# then exec moq-relay with --cluster-connect derived from LEADER_URL so
# the operator only has to set the URL in one place.
#
# Required env:
#   EDGE_HOSTNAME    LE cert filename + cluster-node identity
#   LEADER_URL       https URL of the mesh leader (e.g. https://mesh.example.com)
#
# Files we wait on:
#   /caddy/caddy/certificates/.../<hostname>.crt        (Caddy LE)
#   /data/cluster.jwt                                    (edge wrote it on enroll)
#   /data/jwks/  has at least one *.jwk                  (edge mirrored /v1/jwks)

set -e

CERT_DIR="/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${EDGE_HOSTNAME}"
CERT_PATH="${CERT_DIR}/${EDGE_HOSTNAME}.crt"

# Strip scheme + path + trailing slash from LEADER_URL → bare host(:port).
# moq-relay's --cluster-connect wants a host:port pair, so default to
# :4443 (the QUIC listener port the leader's relay uses) if the URL
# didn't carry one.
LEADER_HOST_PORT=$(printf '%s' "$LEADER_URL" | sed -E 's@^https?://@@; s@/.*$@@')
case "$LEADER_HOST_PORT" in
  *:*) ;;
  *)   LEADER_HOST_PORT="${LEADER_HOST_PORT}:4443" ;;
esac

echo "moq-relay: cluster-root resolved to $LEADER_HOST_PORT"
echo "moq-relay: waiting for boot dependencies..."

WAITED=0
while true; do
  missing=""
  [ -f "$CERT_PATH" ]                            || missing="$missing cert"
  [ -s /data/cluster.jwt ]                       || missing="$missing cluster.jwt"
  ls /data/jwks/*.jwk >/dev/null 2>&1            || missing="$missing jwks"
  if [ -z "$missing" ]; then
    break
  fi
  WAITED=$((WAITED + 3))
  if [ "$WAITED" = 30 ] || [ "$((WAITED % 60))" = 0 ]; then
    echo "moq-relay: still waiting for:$missing (${WAITED}s elapsed)"
  fi
  sleep 3
done

echo "moq-relay: all dependencies ready, starting"
exec /usr/local/bin/moq-relay \
  --cluster-connect "$LEADER_HOST_PORT" \
  "$@"
