# Linux

Bridge's Linux deployment targets 64-bit Ubuntu/Debian hosts, including Raspberry Pi 5 on arm64.

## Install

```bash
git clone https://github.com/intqwq/Bridge.git
cd Bridge
sudo bash install.sh
```

The installer provisions Docker/Compose, `cloudflared`, `jq`, Bridge state, the `bridge` CLI, the loopback-only NGINX edge and systemd services.

The Cloudflare login flow runs as the operator user rather than root so tunnel credentials remain associated with the human operator account.

## Verify

```bash
sudo systemctl status bridge-edge
sudo systemctl status bridge-cloudflared
sudo bridge list
curl -fsS http://127.0.0.1:18080/healthz
```

## Register an application

Start the application first and bind it to host loopback:

```text
127.0.0.1:18100
```

Then register the application's manifest:

```bash
sudo bridge register ./bridge-registration.json
```

For local-only routing tests:

```bash
sudo bridge register ./bridge-registration.json --no-dns
```

## Remove a route

```bash
sudo bridge unregister my-service
```

Bridge removes only that service's local registry and generated NGINX configuration. The Cloudflare DNS route is intentionally preserved until you remove it or reuse the hostname.

## Uninstall

From the Bridge checkout:

```bash
sudo bash uninstall.sh
```

The uninstaller stops/removes `bridge-edge.service` and `bridge-cloudflared.service`, brings down the Bridge Compose project, removes the installed `bridge` CLI, generated `.env`, Bridge-owned `~/.cloudflared/bridge.yml`, and Bridge state/config.

To keep the registry and generated state for a later reinstall:

```bash
sudo bash uninstall.sh --keep-state
```

The uninstaller deliberately **does not** remove Docker, the `cloudflared` package, Docker/cloudflared apt repositories, the operator's Cloudflare login certificate or tunnel credential JSON, the remote Cloudflare tunnel, or DNS records. Remote resources may be shared or needed for a later reinstall and must be removed explicitly only after verifying that nothing else depends on them.

## State and configuration

Defaults:

```text
/etc/intqwq-bridge/config
/var/lib/intqwq-bridge/registry/
/var/lib/intqwq-bridge/nginx/routes/
~/.cloudflared/bridge.yml
```

Runtime settings belong in `.env`. Application hostnames and origins belong in application-owned registration manifests, never in Bridge's `.env`.

## Updating

Pull the new source and rerun the installer. Persistent registrations live outside the repository checkout.
