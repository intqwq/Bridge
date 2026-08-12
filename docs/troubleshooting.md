# Troubleshooting

Start with the smallest boundary and work outward: application origin, Bridge edge, Cloudflare Tunnel, then public DNS.

## Edge health fails

Check the local endpoint first:

```text
http://127.0.0.1:18080/healthz
```

### Linux

```bash
docker info
docker compose --env-file .env ps
docker compose --env-file .env logs edge
sudo systemctl status bridge-edge
```

### Windows

```powershell
bridge doctor
docker info
docker compose --env-file .env ps
docker compose --env-file .env logs edge
```

On Docker Desktop, make sure host networking is enabled and Docker is using Linux containers. Enhanced Container Isolation must not be enabled with host networking.

## Registration says origin health failed

Bridge deliberately checks the origin directly, not through Cloudflare. Verify that the application is already listening on the exact loopback port from the manifest.

Linux:

```bash
curl -v http://127.0.0.1:18100/healthz
```

Windows:

```powershell
Invoke-WebRequest http://127.0.0.1:18100/healthz
```

Do not solve this by binding the application to `0.0.0.0`. Fix the application startup or loopback listener instead.

## `nginx -t` rejects a registration

Bridge rolls back the attempted route automatically. Inspect the manifest and make sure values stay within the documented schema. Generated files under the Bridge state directory should not be hand-edited.

## Cloudflare login or tunnel listing fails

Run the Cloudflare login command interactively as the Bridge operator and confirm that the account can see the intended zone/tunnel. Network/proxy failures and authentication failures are different problems, so read the `cloudflared` error output before retrying.

## Local routing works but the public hostname does not

Test the local virtual host first:

Linux:

```bash
curl -i -H 'Host: app.example.com' http://127.0.0.1:18080/
```

Windows PowerShell:

```powershell
Invoke-WebRequest http://127.0.0.1:18080/ -Headers @{ Host = 'app.example.com' }
```

If local routing succeeds, inspect the `cloudflared` service and the DNS route. Rerunning `bridge register` is safe and re-syncs DNS for the service.

## Hostname already owned

Bridge will not let one service steal another service's hostname. List registrations, remove/update the owning service deliberately, then register the new manifest.

```text
bridge list
```

## Windows `bridge` command is not found after install

The installer adds Bridge to the machine `PATH`. Open a new terminal so it receives the updated environment. The installed files live under `%ProgramFiles%\intqwq-bridge`.
