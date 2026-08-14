import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("Linux uninstaller removes Bridge locally without deleting shared Cloudflare resources", async () => {
  const [root, uninstall, installer] = await Promise.all([
    read("uninstall.sh"),
    read("deploy/pi/uninstall.sh"),
    read("deploy/pi/install-cli.sh"),
  ]);

  assert.match(root, /deploy\/pi\/uninstall\.sh/);
  assert.match(uninstall, /bridge-cloudflared\.service/);
  assert.match(uninstall, /bridge-edge\.service/);
  assert.match(uninstall, /down --remove-orphans/);
  assert.match(uninstall, /rm -rf -- "\$\{state_dir\}"/);
  assert.match(uninstall, /--keep-state/);
  assert.match(uninstall, /--purge-env/);
  assert.match(uninstall, /\.cloudflared\/bridge\.yml/);
  assert.match(installer, /BRIDGE_CLI_PATH/);
  assert.doesNotMatch(uninstall, /cloudflared tunnel delete/);
  assert.doesNotMatch(uninstall, /tunnel route dns/);
  assert.doesNotMatch(uninstall, /apt-get (?:remove|purge).*docker/i);
  assert.doesNotMatch(uninstall, /apt-get (?:remove|purge).*cloudflared/i);
});

test("Windows uninstaller restores or conservatively preserves a pre-existing cloudflared service", async () => {
  const [root, uninstall, cloudflare] = await Promise.all([
    read("uninstall.ps1"),
    read("deploy/windows/uninstall.ps1"),
    read("deploy/windows/configure-cloudflare.ps1"),
  ]);

  assert.match(root, /deploy\\windows\\uninstall\.ps1/);
  assert.match(uninstall, /cloudflaredServicePreexisting/);
  assert.match(uninstall, /cloudflaredPreviousImagePath/);
  assert.match(uninstall, /Older Bridge install detected without cloudflared ownership metadata/i);
  assert.match(uninstall, /KeepState/);
  assert.match(uninstall, /PurgeEnv/);
  assert.match(cloudflare, /cloudflaredServicePreexisting/);
  assert.match(cloudflare, /cloudflaredPreviousImagePath/);
  assert.match(cloudflare, /cloudflaredPreviousWasRunning/);
  assert.doesNotMatch(uninstall, /tunnel delete/);
  assert.doesNotMatch(uninstall, /route dns/);
});
