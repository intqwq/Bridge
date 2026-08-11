# Bridge

Bridge is a neutral, host-local ingress platform for self-hosted applications.
It owns the machine's public networking layer while applications remain private
loopback origins and register themselves declaratively.

Bridge does **not** contain application hostnames, ports, repository paths, or
application lifecycle logic.

## Architecture

```text
Internet
   |
Cloudflare
   |
one Cloudflare Tunnel
   |
127.0.0.1:18080
   |
Bridge Nginx edge
   |
service registry
   +---- hostname A -> http://127.0.0.1:PORT_A
   +---- hostname B -> http://127.0.0.1:PORT_B
   +---- hostname C -> HTTPS redirect
   +---- ...
```

The invariant is simple:

- Bridge installs first and is healthy with zero registered applications.
- Bridge alone owns the Cloudflare Tunnel and public hostname routing.
- Application origins bind to `127.0.0.1`, never the LAN/public interface.
- Applications call the `bridge` registrar after their local origin is healthy.
- Bridge validates registrations, renders isolated Nginx server blocks, tests
  Nginx before reload, and creates the tunnel DNS route for each hostname.
- Removing one registration does not restart or modify any other application.

## Raspberry Pi install

On 64-bit Ubuntu/Debian:

```bash
git clone https://github.com/intqwq/Bridge.git
cd Bridge
sudo bash install.sh
```

The installer provisions Docker/Compose, `cloudflared`, `jq`, the local Bridge
registry, the `bridge` CLI, the Nginx edge, systemd units, and a locally managed
Cloudflare Tunnel. On first install, `cloudflared tunnel login` opens the normal
Cloudflare authorization flow.

After installation:

```bash
sudo systemctl status bridge-edge
sudo systemctl status bridge-cloudflared
sudo bridge list
curl -fsS http://127.0.0.1:18080/healthz
```

At this point no website is configured. Install applications afterward.

## Registration API

Applications register by passing a JSON manifest to the root-owned CLI:

```json
{
  "version": 1,
  "service": "my-service",
  "routes": [
    {
      "hostname": "app.example.com",
      "origin": "http://127.0.0.1:18090",
      "health_path": "/healthz",
      "client_max_body_size": "8m",
      "proxy_read_timeout_seconds": 60
    },
    {
      "hostname": "www.example.com",
      "redirect_to": "example.com"
    }
  ]
}
```

Then:

```bash
sudo bridge register ./bridge-registration.json
sudo bridge list
```

`register` is idempotent for the same service ID. A service may update its own
hostnames/origin, but it cannot claim a hostname already owned by another
service. Proxy origins are restricted to `http://127.0.0.1:PORT`. Hostnames,
redirect targets, body sizes, and timeouts are validated before any Nginx file
is installed.

A registration with `health_path` is accepted only after that local origin
responds successfully. Bridge runs `nginx -t` before reload and rolls back the
local registration if the generated configuration is rejected.

For local-only testing without touching DNS:

```bash
sudo bridge register ./bridge-registration.json --no-dns
```

## Unregister

```bash
sudo bridge unregister my-service
```

This removes only that service's registry entry and Nginx server blocks, then
reloads the shared edge. Bridge intentionally does not delete the Cloudflare DNS
record because `cloudflared tunnel route dns` manages creation but does not
provide the corresponding published-hostname deletion workflow. Until the DNS
record is removed or reused, requests reach Bridge's default `404` server.

## Persistent state

Default paths:

```text
/etc/intqwq-bridge/config
/usr/local/sbin/bridge
/var/lib/intqwq-bridge/registry/
/var/lib/intqwq-bridge/nginx/routes/
~/.cloudflared/bridge.yml
```

`BRIDGE_STATE_DIR`, `EDGE_PORT`, and `BRIDGE_TUNNEL_NAME` are the only runtime
configuration values in `.env`. Application configuration never belongs there.

## Why host networking is deliberate

Applications bind their origins to host loopback. A normal Docker bridge
container cannot reach a host process that listens only on `127.0.0.1` through
the host-gateway address. The Bridge Nginx container therefore uses
`network_mode: host`, while Nginx itself explicitly listens only on
`127.0.0.1:${EDGE_PORT}`. This gives Bridge access to private origins without
opening the edge or origins to the LAN.

## Adding another application

No Bridge source change is required:

1. Choose an unused loopback port.
2. Start the application on `127.0.0.1:PORT`.
3. Create a registration manifest in the application repository.
4. Run `sudo bridge register <manifest>` from the application installer.
5. On uninstall, run `sudo bridge unregister <service-id>` before stopping the
   local origin.

This is the complete extension mechanism. New subdomains are data, not Bridge
code.
