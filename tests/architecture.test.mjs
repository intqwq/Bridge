import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("Bridge core is application-neutral and loopback-only", async () => {
  const [compose, nginx, env] = await Promise.all([
    read("compose.yml"),
    read("nginx/default.conf.template"),
    read(".env.example"),
  ]);
  const core = `${compose}\n${nginx}\n${env}`;

  assert.match(compose, /network_mode: host/);
  assert.match(compose, /BRIDGE_STATE_DIR/);
  assert.match(compose, /\/nginx\/routes:\/etc\/nginx\/routes:ro/);
  assert.match(nginx, /listen 127\.0\.0\.1:\$\{EDGE_PORT\} default_server/);
  assert.match(nginx, /include \/etc\/nginx\/routes\/\*\.conf/);
  assert.match(env, /^BRIDGE_STATE_DIR=\/var\/lib\/intqwq-bridge$/m);
  assert.match(env, /^BRIDGE_TUNNEL_NAME=bridge$/m);
  assert.doesNotMatch(core, /ALGOQUEST_|INTQWQ_DOMAIN|INTQWQ_ORIGIN|game\.intqwq\.com|www\.intqwq\.com/);
  assert.doesNotMatch(core, /host\.docker\.internal|host-gateway/);
});

test("Bridge registrar accepts manifests instead of site-specific settings", async () => {
  const cli = await read("bin/bridge");
  assert.match(cli, /bridge register <manifest\.json>/);
  assert.match(cli, /\.version == 1/);
  assert.match(cli, /service/);
  assert.match(cli, /routes/);
  assert.match(cli, /Origin must be host loopback HTTP/);
  assert.match(cli, /Hostname .* is already owned by service/);
  assert.match(cli, /nginx -t/);
  assert.match(cli, /nginx -s reload/);
  assert.match(cli, /tunnel route dns --overwrite-dns/);
  assert.match(cli, /bridge unregister/);
  assert.doesNotMatch(cli, /AlgoQuest|intqwq\.com|game\.intqwq\.com/);
});

test("Bridge installs before and independently from applications", async () => {
  const [rootInstall, bootstrap, deploy, systemd] = await Promise.all([
    read("install.sh"),
    read("deploy/pi/bootstrap-ubuntu.sh"),
    read("deploy/pi/deploy.sh"),
    read("deploy/pi/install-systemd.sh"),
  ]);
  assert.match(rootInstall, /deploy\/pi\/bootstrap-ubuntu\.sh/);
  assert.match(bootstrap, /install-cli\.sh/);
  assert.match(bootstrap, /configure-cloudflare\.sh/);
  assert.match(deploy, /edge ready at 127\.0\.0\.1/);
  assert.doesNotMatch(deploy, /api\/health|ALGOQUEST|INTQWQ/);
  assert.match(systemd, /Description=Bridge neutral ingress edge/);
  assert.doesNotMatch(systemd, /Requires=.*algoquest|Requires=.*intqwq-site/i);
});

test("Cloudflare tunnel is hostname-agnostic", async () => {
  const cloudflare = await read("deploy/pi/configure-cloudflare.sh");
  assert.match(cloudflare, /ingress:\n  - service: http:\/\/127\.0\.0\.1:\$\{edge_port\}/);
  assert.doesNotMatch(cloudflare, /hostname:/);
  assert.doesNotMatch(cloudflare, /tunnel route dns --overwrite-dns/);
  assert.match(cloudflare, /BRIDGE_TUNNEL_ID/);
  assert.match(cloudflare, /No application hostname is configured/);
});

test("Bridge has no cross-application destructive installer", async () => {
  const bootstrap = await read("deploy/pi/bootstrap-ubuntu.sh");
  assert.doesNotMatch(bootstrap, /clean-install|ERASE-|docker volume rm/);
});
