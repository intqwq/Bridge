# Windows

Bridge supports Windows 10/11 hosts through Docker Desktop running Linux containers.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Docker Desktop 4.34 or newer
- Linux containers
- Docker Desktop host networking enabled
- `cloudflared` available on `PATH` for public Cloudflare Tunnel use
- an elevated PowerShell/Terminal for installation and route mutations

In Docker Desktop, enable **Settings > Resources > Network > Enable host networking**, then apply/restart Docker Desktop. Enhanced Container Isolation is not compatible with host networking.

## Install

From an elevated PowerShell:

```powershell
git clone https://github.com/intqwq/Bridge.git
cd Bridge
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

The installer creates Bridge state under `%ProgramData%\intqwq-bridge`, installs the `bridge` command under `%ProgramFiles%\intqwq-bridge`, starts the NGINX edge, and configures `cloudflared` as a Windows service.

For local-only development without Cloudflare:

```powershell
.\install.ps1 -SkipCloudflare
```

## Verify

Open a new elevated terminal after installation:

```powershell
bridge doctor
bridge status
bridge list
Invoke-WebRequest http://127.0.0.1:18080/healthz
```

## Register an application

The application must already be listening on a loopback address such as `127.0.0.1:18100`.

```powershell
bridge validate .\bridge-registration.json
bridge register .\bridge-registration.json
```

To test routing without creating/updating Cloudflare DNS:

```powershell
bridge register .\bridge-registration.json --no-dns
```

## Automation-friendly output

```powershell
bridge list --json
bridge status --json
bridge inspect my-service
```

## Cloudflare service ownership

Bridge uses the host's `cloudflared` Windows service for its catch-all tunnel configuration. If that service already exists, current installs record its previous command line and running state before Bridge takes control. The uninstaller restores that prior configuration. If Bridge created the service, the uninstaller removes it.

Older Bridge installs did not record that ownership metadata. Their uninstaller takes the conservative path: if the service points at Bridge but its previous configuration is unknown, it stops the service and leaves it installed rather than deleting something that may have predated Bridge.

Do not run a second application-specific Cloudflare Tunnel service on the same host. Register application hostnames through Bridge instead.

## Uninstall

From an elevated PowerShell in the Bridge checkout:

```powershell
.\uninstall.ps1
```

To preserve `%ProgramData%\intqwq-bridge` for a later reinstall:

```powershell
.\uninstall.ps1 -KeepState
```

The uninstaller brings down the Bridge Compose project, removes the Bridge CLI and its machine `PATH` entry, removes generated runtime configuration/state unless requested otherwise, and safely handles the `cloudflared` service ownership described above.

It deliberately **does not** uninstall Docker Desktop, remove the `cloudflared` executable, delete the user's `%USERPROFILE%\.cloudflared` account credentials, or delete the remote Cloudflare tunnel/DNS records. Those resources may be shared and must be removed explicitly only after verifying that nothing else depends on them.

## Updating

Pull the new Bridge source and rerun `install.ps1`. Service registrations live under `%ProgramData%` and are not part of the Git checkout.
