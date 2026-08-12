# Registration manifest reference

Applications integrate with Bridge by shipping a JSON manifest. The current schema version is `1`; the machine-readable schema is in `schema/manifest-v1.schema.json`.

## Example

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

## Top-level fields

| Field | Required | Meaning |
| --- | --- | --- |
| `version` | yes | Must be `1`. |
| `service` | yes | Stable service ID: lowercase letters/numbers plus `_` or `-`, maximum 64 characters. |
| `routes` | yes | Non-empty array of proxy or redirect routes. |

## Route fields

Every route needs `hostname` and exactly one of `origin` or `redirect_to`.

| Field | Required | Meaning |
| --- | --- | --- |
| `hostname` | yes | Lowercase DNS hostname owned by this service. |
| `origin` | one-of | Local HTTP origin. Must be exactly `http://127.0.0.1:PORT`, with port `1..65535`. |
| `redirect_to` | one-of | Lowercase target hostname for an HTTPS `308` redirect. |
| `health_path` | no | Path checked directly against the origin before registration, for example `/healthz`. |
| `client_max_body_size` | no | NGINX body-size value such as `8m` or `1g`. |
| `proxy_read_timeout_seconds` | no | Upstream read timeout from `1` to `3600`; default is `60`. |

## Ownership and updates

A hostname may belong to only one registered service. Registering the same service ID again is an update and may replace that service's own routes, but it cannot take a hostname owned by another service.

## Transaction semantics

Registration proceeds in this order:

1. Parse and validate the manifest.
2. Check hostname ownership conflicts.
3. Run requested origin health checks.
4. Render registry and NGINX route files.
5. Run `nginx -t` inside the Bridge edge.
6. Reload NGINX.
7. Roll back the local files if validation/reload fails.
8. Sync Cloudflare DNS unless `--no-dns` was requested.

DNS synchronization happens after local activation. A DNS failure therefore does not destroy a locally valid route; fix Cloudflare access and rerun registration.

## Application installer contract

Application repositories should:

1. start their local origin on an unused `127.0.0.1` port;
2. wait for application health;
3. run `bridge register <manifest>`;
4. on uninstall, run `bridge unregister <service-id>` before removing the origin.

They should never edit Bridge state or NGINX configuration directly.
