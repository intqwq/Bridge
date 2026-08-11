import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("both sites are equal private origins behind one Bridge edge", async () => {
  const [compose, nginx, env] = await Promise.all([
    read("compose.yml"),
    read("nginx/default.conf.template"),
    read(".env.example"),
  ]);

  assert.match(compose, /name: intqwq-bridge/);
  assert.match(compose, /127\.0\.0\.1:\$\{EDGE_PORT:-18080\}:8080/);
  assert.doesNotMatch(compose, /EDGE_BIND_ADDRESS/);
  assert.doesNotMatch(env, /EDGE_BIND_ADDRESS/);
  assert.match(compose, /host\.docker\.internal:host-gateway/);
  assert.match(env, /ALGOQUEST_ORIGIN=http:\/\/host\.docker\.internal:18081/);
  assert.match(env, /INTQWQ_ORIGIN=http:\/\/host\.docker\.internal:18082/);
  assert.match(nginx, /server_name \$\{ALGOQUEST_DOMAIN\}/);
  assert.match(nginx, /server_name \$\{INTQWQ_DOMAIN\}/);
  assert.match(nginx, /proxy_pass \$\{ALGOQUEST_ORIGIN\}/);
  assert.match(nginx, /proxy_pass \$\{INTQWQ_ORIGIN\}/);
  assert.match(nginx, /client_max_body_size 8m/);
  assert.doesNotMatch(compose, /LEGACY_SHARED_ORIGIN/);
  assert.doesNotMatch(env, /LEGACY_SHARED_ORIGIN/);
  assert.doesNotMatch(nginx, /legacy|LEGACY_SHARED_ORIGIN/);
  assert.doesNotMatch(nginx, /\/srv\/intqwq|AlgoQuest\/compose\.yml/);
});

test("root installer delegates only to Bridge's Pi bootstrap", async () => {
  const installer = await read("install.sh");
  assert.match(installer, /deploy\/pi\/bootstrap-ubuntu\.sh/);
  assert.doesNotMatch(installer, /AlgoQuest|intqwq\.com\/deploy/);
});

test("clean installer erases old data only after explicit confirmation", async () => {
  const installer = await read("deploy/pi/clean-install.sh");

  assert.match(installer, /operator_home.*AlgoQuest/);
  assert.match(installer, /operator_home.*intqwq\.com/);
  assert.match(installer, /ERASE-ALGOQUEST-DATABASE/);
  assert.match(installer, /--plan/);
  assert.match(installer, /down --remove-orphans --volumes/);
  assert.match(installer, /docker volume rm/);
  assert.match(installer, /algoquest-postgres-data/);
  assert.match(installer, /SELECT count\(\*\) FROM users/);
  assert.match(installer, /user_count.*== "0"/s);
  assert.match(installer, /RESEND_API_KEY/);
  assert.match(installer, /TURNSTILE_SECRET_KEY/);
  assert.match(installer, /cloudflared tunnel delete -f/);
  assert.doesNotMatch(installer, /pg_dump|pg_restore/);

  const algoquestInstall = installer.indexOf("Installing a fresh empty AlgoQuest origin");
  const intqwqInstall = installer.indexOf("Installing a fresh intqwq.com origin");
  const bridgeInstall = installer.indexOf("Installing the only public edge");
  assert.ok(algoquestInstall < intqwqInstall);
  assert.ok(intqwqInstall < bridgeInstall);
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
