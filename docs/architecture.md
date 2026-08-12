# Architecture

Bridge is a host-local ingress control plane for small self-hosted machines. It deliberately separates application lifecycle from public networking.

## Data flow

```text
Internet
  |
Cloudflare DNS + Tunnel
  |
cloudflared (one host-owned tunnel)
  |
http://127.0.0.1:18080
  |
Bridge NGINX edge
  |
validated service registry
  +-- app.example.com  -> http://127.0.0.1:18100
  +-- api.example.com  -> http://127.0.0.1:18101
  +-- www.example.com  -> redirect
```

## Responsibilities

Bridge owns:

- the single Cloudflare Tunnel used by the host;
- public hostname to local-origin routing;
- generated NGINX configuration;
- route validation, conflict detection, health gating, reload and rollback;
- the registry of which service owns each hostname.

Applications own:

- their process/container lifecycle;
- their local port;
- their data, database and workers;
- a small Bridge registration manifest shipped in their own repository.

Applications must not install their own reverse proxy, Cloudflare Tunnel, public listener, or Bridge route files.

## Security invariants

1. Application proxy origins are restricted to `http://127.0.0.1:PORT`.
2. The NGINX edge itself listens on host loopback only.
3. A hostname has exactly one owning service.
4. Registrations are validated before they touch active routing.
5. Optional origin health checks must pass before activation.
6. NGINX must accept the generated configuration before reload.
7. A failed reload restores the previous registry and route files.
8. Bridge contains no application-specific hostnames or repository paths.

## Why host networking

The NGINX container must reach applications that intentionally bind only to host loopback. Bridge therefore uses Docker host networking and still configures NGINX to listen only on `127.0.0.1`.

On Linux this is Docker Engine host networking. On Windows, Bridge targets Linux containers on Docker Desktop 4.34+ with host networking enabled. This preserves one architecture across both platforms instead of weakening origins to LAN-visible bindings.

## Persistent state

Linux defaults:

```text
/etc/intqwq-bridge/config
/var/lib/intqwq-bridge/registry/
/var/lib/intqwq-bridge/nginx/routes/
~/.cloudflared/
```

Windows defaults:

```text
%ProgramData%\intqwq-bridge\config.json
%ProgramData%\intqwq-bridge\registry\
%ProgramData%\intqwq-bridge\nginx\routes\
%ProgramData%\intqwq-bridge\cloudflared\
%ProgramFiles%\intqwq-bridge\bridge.ps1
```

The registry is intentionally plain JSON. Generated NGINX route files are derived state and should never be edited by hand.
