# Contributing to Bridge

Thanks for helping improve Bridge. The project values small, auditable changes and a strict separation between application code and the host networking layer.

## Development principles

- Keep Bridge application-neutral. Do not add real application hostnames, ports or repository paths to the core.
- Keep proxy origins loopback-only.
- Preserve transactional registration: validate, render, `nginx -t`, reload, rollback on failure.
- Keep Linux and Windows behavior aligned when adding CLI features.
- Prefer declarative manifest fields over application-specific switches.
- Avoid adding another public reverse proxy or tunnel implementation without a clear architectural reason.

## Local checks

Requirements for repository tests:

- Node.js 22+
- Docker with Compose for Linux integration tests
- PowerShell 5.1+ or PowerShell 7+ for Windows script parsing

Run the portable test suite:

```bash
npm test
```

On Linux, also validate shell syntax and Compose:

```bash
bash -n install.sh bin/bridge deploy/pi/*.sh
docker compose --env-file .env.example config --quiet
```

On Windows, parse every PowerShell script before submitting a change:

```powershell
$files = @('.\install.ps1', '.\bin\bridge.ps1') + (Get-ChildItem .\deploy\windows\*.ps1).FullName
foreach ($file in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count) { $errors | Format-List; throw "PowerShell parse failed: $file" }
}
```

## Pull requests

Keep PRs focused. Explain the boundary or failure mode being changed, include tests for new manifest behavior, and document any operator-visible change.

Changes that weaken loopback-only origins, skip NGINX validation, silently overwrite hostname ownership or embed application-specific routing are unlikely to be accepted.

## Commit style

Conventional-style subjects are welcome, for example:

```text
feat: add registrar diagnostics
fix: roll back route after reload failure
docs: explain Windows host networking
```
