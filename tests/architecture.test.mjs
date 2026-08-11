import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("both sites are equal peers behind one Bridge edge", async () => {
  const [compose, nginx, env] = await Promise.all([
    read("compose.yml"),
    read("nginx/default.conf.template"),
    read(".env.example"),
  ]);

  assert.match(compose, /name: intqwq-bridge/);
  assert.match(compose, /127\.0\.0\.1\}:\$\{EDGE_PORT:-18080\}:8080/);
  assert.match(compose, /host\.docker\.internal:host-gateway/);
  assert.match(env, /ALGOQUEST_ORIGIN=http:\/\/host\.docker\.internal:18081/);
  assert.match(env, /INTQWQ_ORIGIN=http:\/\/host\.docker\.internal:18082/);
  assert.match(env, /LEGACY_SHARED_ORIGIN=http:\/\/host\.docker\.internal:8080/);
  assert.match(nginx, /server_name \$\{ALGOQUEST_DOMAIN\}/);
  assert.match(nginx, /server_name \$\{INTQWQ_DOMAIN\}/);
  assert.match(nginx, /proxy_pass \$\{ALGOQUEST_ORIGIN\}/);
  assert.match(nginx, /proxy_pass \$\{INTQWQ_ORIGIN\}/);
  assert.match(nginx, /client_max_body_size 8m/);
  assert.match(nginx, /error_page 502 504 = @algoquest_legacy/);
  assert.match(nginx, /error_page 502 504 = @intqwq_legacy/);
  assert.doesNotMatch(nginx, /\/srv\/intqwq|AlgoQuest\/compose\.yml/);
});

test("shared-host migration preserves AlgoQuest data and avoids the live port", async () => {
  const migration = await read("deploy/pi/migrate-from-shared.sh");

  assert.match(migration, /operator_home.*AlgoQuest/);
  assert.match(migration, /operator_home.*intqwq\.com/);
  assert.match(migration, /BRIDGE_MIGRATION_EDGE_PORT:-18080/);
  assert.match(migration, /pg_dump.*-Fc/);
  assert.match(migration, /pg_restore -l/);
  assert.match(migration, /POSTGRES_VOLUME/);
  assert.match(migration, /stop api judge judge-worker/);
  assert.match(migration, /counts\.before\.csv/);
  assert.match(migration, /database-mount\.after\.txt/);
  assert.match(migration, /MIGRATION_ALLOW_LOCAL_BACKUP/);
  assert.match(migration, /--retire-legacy/);
  assert.doesNotMatch(migration, /compose[^\n]*down[^\n]*-v/);
  assert.doesNotMatch(migration, /docker volume rm/);
});

test("one tunnel route targets the shared edge for every hostname", async () => {
  const cloudflare = await read("deploy/pi/configure-cloudflare.sh");
  const serviceLine = "service: http://127.0.0.1:${edge_port}";

  assert.equal(cloudflare.split(serviceLine).length - 1, 3);
  assert.match(cloudflare, /hostname: \$\{algoquest_domain\}/);
  assert.match(cloudflare, /hostname: \$\{intqwq_domain\}/);
  assert.match(cloudflare, /hostname: \$\{intqwq_www_domain\}/);
  assert.match(cloudflare, /Description=Shared intqwq Cloudflare Tunnel/);
  assert.doesNotMatch(cloudflare, /Requires=algoquest\.service/);
});

test("Bridge startup is independent from either application service", async () => {
  const [systemd, deploy] = await Promise.all([
    read("deploy/pi/install-systemd.sh"),
    read("deploy/pi/deploy.sh"),
  ]);
  assert.match(systemd, /Description=Shared intqwq edge router/);
  assert.doesNotMatch(systemd, /Requires=.*algoquest|Requires=.*intqwq-site/);
  assert.match(systemd, /Restart=on-failure/);
  assert.match(systemd, /--wait --wait-timeout/);
  assert.match(deploy, /\/api\/health/);
});
