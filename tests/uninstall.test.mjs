import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("Linux uninstaller is Bridge-scoped and preserves shared infrastructure", async () => {
  const [root, uninstall, docs] = await Promise.all([
    read("uninstall.sh"),
    read("deploy/pi/uninstall.sh"),
    read("docs/linux.md"),
  ]);

  assert.match(root, /deploy\/pi\/uninstall\.sh/);
  assert.match(uninstall, /bridge-cloudflared\.service/);
  assert.match(uninstall, /bridge-edge\.service/);
  assert.match(uninstall, /docker compose .* down --remove-orphans/);
  assert.match(uninstall, /rm -rf -- "\$\{state_dir\}"/);
  assert.match(uninstall, /--keep-state/);
  assert.doesNotMatch(uninstall, /cloudflared tunnel delete/);
  assert.doesNotMatch(uninstall, /apt-get (?:remove|purge).*docker/i);
  assert.doesNotMatch(uninstall, /apt-get (?:remove|purge).*cloudflared/i);
  assert.match(docs, /remote Cloudflare tunnel/);
});

test("Windows uninstaller restores or conservatively preserves cloudflared service ownership", async () => {
  const [root, uninstall, cloudflare, docs] = await Promise.all([
    read("uninstall.ps1"),
    read("deploy/windows/uninstall.ps1"),
    read("deploy/windows/configure-cloudflare.ps1"),
    read("docs/windows.md"),
  ]);

  assert.match(root, /deploy\\windows\\uninstall\.ps1/);
  assert.match(uninstall, /cloudflaredServicePreexisting/);
  assert.match(uninstall, /cloudflaredPreviousImagePath/);
  assert.match(uninstall, /older Bridge install without cloudflared ownership metadata/i);
  assert.match(uninstall, /-KeepState|KeepState/);
  assert.match(cloudflare, /cloudflaredServicePreexisting/);
  assert.match(cloudflare, /cloudflaredPreviousImagePath/);
  assert.match(cloudflare, /cloudflaredPreviousWasRunning/);
  assert.doesNotMatch(uninstall, /tunnel delete/);
  assert.doesNotMatch(uninstall, /Docker Desktop.*uninstall/i);
  assert.match(docs, /restores that prior configuration/i);
});
