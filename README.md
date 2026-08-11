# Bridge

Bridge is the **only Internet boundary** for the intqwq services hosted on one
machine. It owns public hostname routing, the shared Nginx edge, Cloudflare DNS
routes, and the single Cloudflare Tunnel process for `game.intqwq.com`,
`intqwq.com`, and `www.intqwq.com`.

AlgoQuest and intqwq.com remain independent application origins. They may own
application-local HTTP servers and internal Docker networking, but they do not
own public ingress, DNS routing, TLS/tunnel lifecycle, or Cloudflare Tunnel
services.

## Architecture contract

```text
Internet
  -> Cloudflare
  -> one Cloudflare Tunnel (bridge-cloudflared.service)
  -> http://127.0.0.1:18080
  -> Bridge Nginx (Host-based public routing)
       -> game.intqwq.com       -> AlgoQuest origin 127.0.0.1:18081
       -> intqwq.com / www      -> intqwq.com origin 127.0.0.1:18082
```

The three host ports are deliberately loopback-only:

| Owner | Address | Purpose |
| --- | --- | --- |
| Bridge | `127.0.0.1:18080` | sole tunnel target and public hostname router |
| AlgoQuest | `127.0.0.1:18081` | private application origin |
| intqwq.com | `127.0.0.1:18082` | private application origin |

Bridge's Compose model hard-codes its bind address to `127.0.0.1`; it is not an
environment option. The application installers similarly enforce their private
origin bindings. Public exposure therefore has one owner instead of three
independent knobs.

The edge stays running when either origin is updated. An unavailable origin
returns an isolated upstream failure while the other route and the Cloudflare
connection continue to work. No application repository mounts files into,
restarts, or edits Bridge.

## Raspberry Pi installation

Deploy the two application origins first, then Bridge:

```bash
# 1. AlgoQuest
cd ~/AlgoQuest
sudo bash install.sh

# 2. intqwq.com
cd ~/intqwq.com
sudo bash install.sh

# 3. Bridge, always last
cd ~/Bridge
sudo bash install.sh
```

The first Bridge installation installs Docker and `cloudflared` when needed,
starts the edge, verifies both origins through the actual hostname routes,
creates or reuses the named tunnel `bridge`, maps all three public hostnames to
the one local edge URL, and installs these boot services:

- `bridge-edge.service`
- `bridge-cloudflared.service`

The first Cloudflare setup opens one browser authorization flow. Select the
`intqwq.com` zone. Tunnel credentials stay in the operator's private
`~/.cloudflared` directory and the generated `bridge.yml` is mode `0600`.

Useful commands:

```bash
sudo bash deploy/pi/status.sh
sudo systemctl restart bridge-edge
sudo systemctl restart bridge-cloudflared
docker compose --env-file .env logs -f edge
```

Set `BRIDGE_ALLOW_UNHEALTHY_ORIGINS=1` only when intentionally bringing the edge
up before one of the origins. The normal bootstrap expects both applications to
be healthy before Cloudflare routing is configured.

## Configuration

Copy `.env.example` to `.env` when configuring manually. The normal production
contract is:

```dotenv
EDGE_PORT=18080
ALGOQUEST_DOMAIN=game.intqwq.com
INTQWQ_DOMAIN=intqwq.com
INTQWQ_WWW_DOMAIN=www.intqwq.com
ALGOQUEST_ORIGIN=http://host.docker.internal:18081
INTQWQ_ORIGIN=http://host.docker.internal:18082
```

`host.docker.internal` is mapped to Docker's host gateway so Bridge can reach
the two loopback-bound host origins from inside its edge container.

No tunnel credentials, API tokens, application secrets, Resend keys, or
Turnstile secrets belong in this repository.

## Destructive clean installation

Use the clean installer only when the old deployment and **all AlgoQuest data**
may be discarded. It expects `~/AlgoQuest` and `~/intqwq.com` and runs from the
Bridge checkout:

```bash
sudo bash deploy/pi/clean-install.sh --plan
sudo bash deploy/pi/clean-install.sh
```

The script refuses dirty repositories, validates required external secrets,
requires the exact phrase `ERASE-ALGOQUEST-DATABASE`, deletes the PostgreSQL and
Judge volumes, removes obsolete pre-Bridge services, installs fresh application
origins, installs Bridge last, and removes the obsolete remote tunnel named
`algoquest` if it still exists. This is intentionally not a migration or backup
tool.

## Validation

```bash
npm test
docker compose --env-file .env.example config --quiet
bash -n install.sh deploy/pi/*.sh
```
