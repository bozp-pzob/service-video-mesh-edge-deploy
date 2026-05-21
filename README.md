# service-video-mesh-edge-deploy

Run an edge node that adds bandwidth to a [service-video-mesh](https://github.com/bozp-pzob/service-video-mesh) leader. **Permissionless** — no operator coordination, no shared secrets. You bring a public host with a DNS name; everything else is bootstrapped at boot.

If the leader you're attaching to is set up with the [EdDSA keyring](https://github.com/bozp-pzob/service-video-mesh-deploy) (default since 2026-05), your edge can join by setting three env vars and running `docker compose up -d`. The leader mints your cluster-attach JWT, publishes verify keys at `/v1/jwks`, and routes viewers to you via `/v1/assign`.

## What an edge does

- Runs a `moq-relay` in cluster-member mode, attached upstream to the leader's relay.
- Terminates viewer WebTransport sessions on `udp/4443`.
- Validates viewer-subscribe JWTs locally with the leader's public verify keys (you don't hold the signing secret).
- Reports liveness + capacity + measured egress to the leader on a heartbeat. The leader's `/v1/assign` weights edges by health and routes viewers accordingly.
- Optional: declares a payout address so viewer-signed delivery receipts pay this edge directly.

## What you need

- A host with a **public IPv4** and DNS A record pointing at it. Free wildcard DNS like `nip.io` works (`159-223-116-200.nip.io`).
- Open ports: `tcp/80`, `tcp/443`, `udp/4443`.
- Docker + Docker Compose v2.
- The leader you're attaching to must be on Track-B (EdDSA keyring). Confirm:
  ```bash
  curl -s https://<leader>/v1/jwks | jq '.keys | length'
  ```
  Expect `>=1`. If you see `0`, the leader hasn't rolled to EdDSA yet — ask the operator to run `bootstrap/rotate-to-eddsa.sh`.

## Setup

```bash
git clone https://github.com/bozp-pzob/service-video-mesh-edge-deploy.git
cd service-video-mesh-edge-deploy

cp .env.example .env
# Fill in:
#   EDGE_HOSTNAME     edge1.example.com   (your DNS, must resolve to this host)
#   LEADER_URL        https://mesh.example.com
#   CADDY_ACME_EMAIL  ops@example.com
#   LEADER_PUBKEY     <paste from `curl $LEADER_URL/v1/version | jq -r .leaderPubkey`>
$EDITOR .env

docker compose up -d

# Watch the boot sequence. Expect:
#   caddy        certificate obtained for $EDGE_HOSTNAME
#   edge-node    edge: wrote cluster token from leader
#   edge-node    edge: jwks synced  count=1
#   moq-relay    all dependencies ready, starting
#   moq-relay    cluster: peer connected (or similar)
docker compose logs -f
```

That's it. Within ~30s the leader sees your edge enrolled and starts routing viewers to you on the next `/v1/assign` request.

## Verify the edge is taking traffic

```bash
# On the leader operator's side:
curl -s https://<leader>/v1/dashboard/edges | jq '.[] | select(.publicEndpoint | contains("YOUR_EDGE_HOSTNAME"))'

# Or from your edge host — count active WebTransport viewers:
docker compose exec moq-relay sh -c 'ss -aH -p udp src :4443 | wc -l'
```

## Trust model

The leader operator decides what to sign and what to publish. You decide what bandwidth to share. Neither side trusts the other with anything risky:

- **You don't hold mint authority.** The leader's verify keys are Ed25519 public halves; possessing them lets you validate viewer JWTs but not forge new ones. No symmetric secrets cross the trust boundary.
- **The leader doesn't trust your declared capacity.** Misreporting your `EDGE_MAX_EGRESS_BPS` or `EDGE_MAX_CONSUMERS` just makes the selector route you less traffic — there's no exploit, only self-harm.
- **Open enrollment by default.** The leader accepts any edge that completes the signature challenge. Settlement (if the leader runs on-chain receipts) is gated by reputation + your declared payout address.
- **TOFU pinning available.** Set `LEADER_PUBKEY` in `.env` and the edge refuses to enroll if a MITM substitutes a different leader. The pubkey is published over the leader's HTTPS endpoint, so pinning is a cheap one-time copy-paste.

What the leader **can** do that affects you:
- Decline to route viewers to your edge (selector decision).
- Issue you a cluster JWT that expires sooner than yours.
- Stop responding to `/v1/jwks` — your relay would keep verifying with the keys it already cached.

What the leader **can't** do:
- Make your relay forward traffic that you wouldn't have validated anyway (the JWT auth is end-to-end).
- Sign tokens "as you" — there's no such thing; tokens identify content + permissions, not edges.

## Updating

The `:latest` tag follows mainline. For reproducible deploys, pin in `.env`:

```env
EDGE_IMAGE=ghcr.io/bozp-pzob/service-video-mesh-edge:sha-abc1234
```

When the leader rotates verify keys, your edge picks up the new public JWKs on its next refresh (5 min default) — no restart needed.

When the cluster JWT expires (7d TTL), the edge re-enrolls on its next WSS reconnect and writes a fresh one. The `moq-relay` keeps its existing cluster connection open as long as it's alive; restart the relay container if you want to force a new dial:

```bash
docker compose restart moq-relay
```

## Troubleshooting

**`moq-relay: still waiting for: cluster.jwt jwks (300s elapsed)`**
The edge-node isn't reaching the leader. Check:
- `LEADER_URL` is correct + reachable from the edge host (`curl $LEADER_URL/v1/version`).
- The leader is on Track-B (`curl $LEADER_URL/v1/jwks | jq '.keys'` returns at least one entry).
- `docker compose logs edge` shows enrollment errors.

**`edge: leader pubkey mismatch — possible MITM`**
`LEADER_PUBKEY` in `.env` doesn't match what the leader advertises. Re-fetch and verify the path between you and the leader is what you expect:
```bash
curl -s $LEADER_URL/v1/version | jq -r .leaderPubkey
```

**`moq-relay: cluster: peer authentication failed`**
The cluster JWT the leader issued isn't accepted upstream. Usually means:
- The leader hasn't fully rolled to EdDSA (some JWKs in the keyring are HS256-only).
- The clocks between your host and the leader differ by >5 min (Ed25519 JWTs check `exp`).
Run `timedatectl status` and `docker compose restart moq-relay` after fixing.

**Caddy stuck on `unable to get certificate`**
DNS isn't pointing at this host yet, or `tcp/80` is firewalled. ACME HTTP-01 requires both.

## Architecture references

- Leader codebase: [github.com/bozp-pzob/service-video-mesh](https://github.com/bozp-pzob/service-video-mesh)
- Leader deploy template: [github.com/bozp-pzob/service-video-mesh-deploy](https://github.com/bozp-pzob/service-video-mesh-deploy)
- Underlying transport: [kixelated/moq](https://github.com/kixelated/moq)

## License

MIT. See [LICENSE](./LICENSE).
