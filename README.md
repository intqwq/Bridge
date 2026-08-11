# Bridge

Bridge is the shared public edge for `game.intqwq.com`, `intqwq.com`, and
`www.intqwq.com`. It owns the only shared Nginx process and the only Cloudflare
Tunnel service. AlgoQuest and intqwq.com remain independent application origins;
neither repository mounts files into, restarts, or edits the other one.

## Architecture

```text
Internet
  -> one Cloudflare Tunnel (bridge-cloudflared.service)
  -> one loopback route (http://127.0.0.1:8080)
  -> Bridge Nginx (Host-based routing)
       -> game.intqwq.com       -> AlgoQuest origin 127.0.0.1:18081
       -> intqwq.com / www      -> intqwq.com origin 127.0.0.1:18082
```

The edge stays running when either origin is updated. An unavailable origin
returns an isolated `502`; the other site and the Cloudflare connection continue
to work. During migration, connection failures fall back to the old shared
gateway on loopback port `8080`; after migration that bounded fallback is simply
inactive. All public ports are loopback-bound, so Cloudflare Tunnel is the only
Internet-facing path.

## Origin contract

| Origin | Loopback address | Readiness path |
| --- | --- | --- |
| AlgoQuest | `http://127.0.0.1:18081` | `/healthz` |
| intqwq.com | `http://127.0.0.1:18082` | `/healthz` |
| Bridge edge | `http://127.0.0.1:8080` | `/healthz` |

The container uses `host.docker.internal` to reach the two host-bound origins.
Linux support is supplied by Compose's `host-gateway` mapping.

## Raspberry Pi deployment

Deploy both origins first, then Bridge:

```bash
# In AlgoQuest
sudo bash deploy/pi/bootstrap-ubuntu.sh

# In intqwq.com
sudo bash deploy/pi/bootstrap-ubuntu.sh

# In Bridge
sudo bash deploy/pi/bootstrap-ubuntu.sh
```

The Bridge bootstrap installs Docker and `cloudflared` when needed, starts the
edge, verifies both origins through the actual hostname routes, creates or reuses
a tunnel named `bridge`, routes all public hostnames to the same local edge URL,
and installs these boot services:

- `bridge-edge.service`
- `bridge-cloudflared.service`

For a zero-downtime migration, install Bridge first while the old shared gateway
still listens on `8080`, then migrate intqwq.com to `18082`, and finally migrate
AlgoQuest to `18081`. Bridge automatically prefers each new origin as it becomes
available and falls back to the old shared route until then.

The first Cloudflare setup opens one browser authorization flow. It does not
delete or stop legacy tunnel processes. After both public sites have been
verified through Bridge, retire them explicitly:

```bash
sudo systemctl disable --now algoquest-cloudflared.service
docker rm -f intqwq-cloudflared 2>/dev/null || true
```

Useful commands:

```bash
sudo bash deploy/pi/status.sh
sudo systemctl restart bridge-edge
sudo systemctl restart bridge-cloudflared
docker compose --env-file .env logs -f edge
```

Set `BRIDGE_ALLOW_UNHEALTHY_ORIGINS=1` only when intentionally installing the
edge before one of the application origins. Cloudflare configuration is not
published until the normal readiness checks pass.

## Configuration

Copy `.env.example` to `.env`. The defaults match the production contract:

```dotenv
EDGE_BIND_ADDRESS=127.0.0.1
EDGE_PORT=8080
ALGOQUEST_DOMAIN=game.intqwq.com
INTQWQ_DOMAIN=intqwq.com
INTQWQ_WWW_DOMAIN=www.intqwq.com
ALGOQUEST_ORIGIN=http://host.docker.internal:18081
INTQWQ_ORIGIN=http://host.docker.internal:18082
LEGACY_SHARED_ORIGIN=http://host.docker.internal:8080
```

No tunnel credentials, API tokens, or application secrets belong in this
repository. Named-tunnel credentials stay in the operator's private
`~/.cloudflared` directory and the generated ingress file is mode `0600`.

## Validation

```bash
npm test
docker compose --env-file .env.example config --quiet
bash -n deploy/pi/*.sh
```
