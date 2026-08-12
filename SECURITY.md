# Security Policy

## Reporting a vulnerability

Please do not publish exploitable details in a public issue before a fix is available. Use GitHub's private vulnerability reporting feature for this repository when available, or contact the maintainer privately through the contact method listed on the maintainer's GitHub profile.

Include the affected Bridge version/commit, host platform, reproduction steps, expected impact and any proposed mitigation.

## Security model

Bridge is designed around a narrow trust boundary:

- public traffic enters through a host-owned Cloudflare Tunnel;
- the Bridge NGINX edge listens only on host loopback;
- application origins are restricted to `http://127.0.0.1:PORT`;
- manifests are validated before routing changes;
- hostname ownership conflicts are rejected;
- optional origin health checks run before activation;
- NGINX configuration is tested before reload and local state is rolled back on failure.

Bridge's registration command is an administrative operation. Anyone who can run it with the required elevated privileges can change public hostname routing on the host.

## Secrets

Do not commit `.env`, Cloudflare account certificates, tunnel credential JSON files or generated state directories. Tunnel credentials belong in the platform-specific persistent state location documented in the installation guides.

## Supported versions

Security fixes target the current `main` branch. Older commits may not receive backports while the project remains pre-stable.
