# Bridge

Bridge is the shared public edge for `game.intqwq.com`, `intqwq.com`, and
`www.intqwq.com`. It owns the only shared Nginx process and the only Cloudflare
Tunnel service. AlgoQuest and intqwq.com remain independent application origins;
neither repository mounts files into, restarts, or edits the other one.

## Architecture

```text
Internet
  -> one Cloudflare Tunnel (bridge-cloudflared.service)
  -> one loopback route (http://127.0.0.1:18080)
  -> Bridge Nginx (Host-based routing)
       -> game.intqwq.com       -> AlgoQuest origin 127.0.0.1:18081
       -> intqwq.com / www      -> intqwq.com origin 127.0.0.1:18082
```

The edge stays running when either origin is updated. An unavailable origin
returns an isolated `502`; the other site and the Cloudflare connection continue
to work. There is no legacy or cross-repository fallback. All public ports are
loopback-bound, so Cloudflare Tunnel is the only Internet-facing path.

## Origin contract

| Origin | Loopback address | Readiness path |
| --- | --- | --- |
| AlgoQuest | `http://127.0.0.1:18081` | `/healthz` |
| intqwq.com | `http://127.0.0.1:18082` | `/healthz` |
| Bridge edge | `http://127.0.0.1:18080` | `/healthz` |

The container uses `host.docker.internal` to reach the two host-bound origins.
Linux support is supplied by Compose's `host-gateway` mapping.

## Destructive clean installation

Use the clean installer when the old shared deployment and all AlgoQuest data
may be discarded. It expects `~/AlgoQuest` and `~/intqwq.com` and runs from the
Bridge checkout:

```bash
sudo bash deploy/pi/clean-install.sh --plan
sudo bash deploy/pi/clean-install.sh
```

The script:

- refuses dirty repositories and validates required external secrets first;
- preserves only Resend, Turnstile, owner, and previous deployment configuration;
- requires the exact phrase `ERASE-ALGOQUEST-DATABASE`;
- stops and removes obsolete and current runtime services;
- permanently deletes the PostgreSQL and Judge volumes without backing them up;
- removes the old shared static state and systemd units;
- creates fresh environment files and rotates internal credentials;
- installs an empty AlgoQuest origin on `18081` and confirms it has zero users;
- installs intqwq.com on `18082`; and
- installs Bridge last as the sole edge and Cloudflare tunnel on `18080`, then
  deletes the obsolete named `algoquest` tunnel if it still exists.

This is intentionally not a migration or recovery tool. Run
`sudo bash deploy/pi/clean-install.sh --help` before using it.

## Fresh Raspberry Pi deployment

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

The first Cloudflare setup opens one browser authorization flow. Bridge routes
all three public hostnames through its single loopback edge.

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
EDGE_PORT=18080
ALGOQUEST_DOMAIN=game.intqwq.com
INTQWQ_DOMAIN=intqwq.com
INTQWQ_WWW_DOMAIN=www.intqwq.com
ALGOQUEST_ORIGIN=http://host.docker.internal:18081
INTQWQ_ORIGIN=http://host.docker.internal:18082
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
