# Bridge

**A small, declarative ingress layer for self-hosted applications.**

Bridge owns a machine's public networking boundary so individual applications do not need to know about Cloudflare Tunnel, NGINX configuration, certificates or each other. Applications stay private on host loopback and register public hostnames through a tiny JSON manifest.

[![CI](https://github.com/intqwq/Bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/intqwq/Bridge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Why Bridge?

A self-hosted machine often grows into a thicket of one-off NGINX files, competing tunnels, copied Cloudflare credentials and installers that modify each other's networking. Bridge turns that shared edge into one explicit component.

```text
Internet
   |
Cloudflare DNS + Tunnel
   |
127.0.0.1:18080
   |
Bridge NGINX edge
   |
service registry
   +---- app.example.com  -> http://127.0.0.1:18100
   +---- api.example.com  -> http://127.0.0.1:18101
   +---- www.example.com  -> redirect
```

The rules are intentionally strict:

- Bridge installs and runs with zero applications.
- Bridge alone owns the host's public tunnel and hostname routing.
- Application origins bind to `127.0.0.1`, never the LAN/public interface.
- A hostname can belong to only one service.
- Registrations are health-gated when requested, tested with `nginx -t`, and rolled back if reload fails.
- Application names, ports and repository paths never belong in Bridge core configuration.

## Platform support

| Platform | Status | Runtime |
| --- | --- | --- |
| Ubuntu/Debian x86_64 | Supported | Docker Engine + Compose |
| Ubuntu/Debian arm64, including Raspberry Pi | Supported | Docker Engine + Compose |
| Windows 10/11 | Supported | Docker Desktop 4.34+ using Linux containers and host networking |

See [Linux installation](docs/linux.md) and [Windows installation](docs/windows.md) for platform details.

## Quick start: Linux

```bash
git clone https://github.com/intqwq/Bridge.git
cd Bridge
sudo bash install.sh

sudo bridge list
curl -fsS http://127.0.0.1:18080/healthz
```

## Quick start: Windows

Enable Docker Desktop host networking, then run an elevated PowerShell:

```powershell
git clone https://github.com/intqwq/Bridge.git
cd Bridge
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1

bridge doctor
bridge status
```

For a local-only install without Cloudflare:

```powershell
.\install.ps1 -SkipCloudflare
```

## Uninstall

Linux:

```bash
sudo bash uninstall.sh
```

Windows, from an elevated PowerShell:

```powershell
.\uninstall.ps1
```

The uninstallers remove Bridge-owned local services, containers, CLI files and runtime state. They intentionally preserve Docker/cloudflared packages, Cloudflare account credentials, the remote tunnel, and all Cloudflare DNS records. This keeps unrelated DNS, including mail-routing records, outside Bridge's blast radius.

To preserve the Bridge registry/state while removing the runtime, use `--keep-state` on Linux or `-KeepState` on Windows. Linux and Windows also support `--purge-env` / `-PurgeEnv` when you explicitly want the repository `.env` deleted.

## Register an application

Ship a file such as `bridge-registration.json` in the application repository:

```json
{
  "version": 1,
  "service": "my-service",
  "routes": [
    {
      "hostname": "app.example.com",
      "origin": "http://127.0.0.1:18100",
      "health_path": "/healthz",
      "client_max_body_size": "8m",
      "proxy_read_timeout_seconds": 60
    },
    {
      "hostname": "www.example.com",
      "redirect_to": "app.example.com"
    }
  ]
}
```

Then register it after the local application is healthy:

```text
bridge register ./bridge-registration.json
```

Registration is idempotent for a service ID. To exercise local routing without changing Cloudflare DNS:

```text
bridge register ./bridge-registration.json --no-dns
```

Remove only that application's routes with:

```text
bridge unregister my-service
```

The full contract is documented in [Registration manifest reference](docs/manifest-reference.md) and `schema/manifest-v1.schema.json`.

## Operator commands

Common commands:

```text
bridge register <manifest.json> [--no-dns]
bridge unregister <service-id>
bridge list
```

The Windows CLI additionally exposes diagnostics and automation helpers:

```text
bridge validate <manifest.json>
bridge inspect <service-id>
bridge list --json
bridge status [--json]
bridge doctor
```

## Architecture and security

Bridge uses Docker host networking so the NGINX container can reach host applications that remain bound to loopback. NGINX itself still listens only on `127.0.0.1:${EDGE_PORT}`. This keeps the origin boundary private without introducing per-application Docker networking knowledge into Bridge.

Read [Architecture](docs/architecture.md) for ownership boundaries and [Security Policy](SECURITY.md) for the threat model and reporting process.

## Documentation

- [Architecture](docs/architecture.md)
- [Linux](docs/linux.md)
- [Windows](docs/windows.md)
- [Registration manifest reference](docs/manifest-reference.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## Project philosophy

Bridge is infrastructure glue, not an application platform. New applications should normally require **zero Bridge source changes**: choose a loopback port, start the application, and register a manifest. If adding an application requires editing Bridge itself, that is usually a signal that the abstraction boundary has leaked.

## License

MIT. See [LICENSE](LICENSE).
