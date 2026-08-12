import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("Windows keeps the same loopback-only registrar contract", async () => {
  const [cli, installer, cloudflare, env] = await Promise.all([
    read("bin/bridge.ps1"),
    read("deploy/windows/install.ps1"),
    read("deploy/windows/configure-cloudflare.ps1"),
    read(".env.windows.example"),
  ]);

  assert.match(cli, /http:\/\/127\\\.0\\\.0\\\.1/);
  assert.match(cli, /Hostname .* is already owned by service/);
  assert.match(cli, /nginx', '-t'/);
  assert.match(cli, /nginx', '-s', 'reload'/);
  assert.match(cli, /tunnel route dns --overwrite-dns/);
  assert.match(cli, /Register-Service/);
  assert.match(cli, /Unregister-Service/);
  assert.match(cli, /Doctor/);
  assert.match(cli, /--json/);
  assert.match(installer, /Docker Desktop 4\.34/);
  assert.match(installer, /host networking/i);
  assert.match(cloudflare, /service install/);
  assert.match(cloudflare, /http:\/\/127\.0\.0\.1:\$EdgePort/);
  assert.match(env, /^BRIDGE_STATE_DIR=C:\/ProgramData\/intqwq-bridge$/m);

  const core = `${cli}\n${installer}\n${cloudflare}\n${env}`;
  assert.doesNotMatch(core, /AlgoQuest|game\.intqwq\.com|www\.intqwq\.com|ALGOQUEST_/i);
});

test("public project surfaces a schema and platform documentation", async () => {
  const [schemaText, readme, architecture, windows, linux, manifest, security, contributing] = await Promise.all([
    read("schema/manifest-v1.schema.json"),
    read("README.md"),
    read("docs/architecture.md"),
    read("docs/windows.md"),
    read("docs/linux.md"),
    read("docs/manifest-reference.md"),
    read("SECURITY.md"),
    read("CONTRIBUTING.md"),
  ]);
  const schema = JSON.parse(schemaText);

  assert.equal(schema.properties.version.const, 1);
  assert.equal(schema.properties.routes.minItems, 1);
  assert.match(JSON.stringify(schema), /127\\\\\.0\\\\\.0\\\\\.1/);
  assert.match(readme, /Windows 10\/11/);
  assert.match(readme, /Ubuntu\/Debian arm64/);
  assert.match(readme, /MIT/);
  assert.match(architecture, /Security invariants/);
  assert.match(windows, /Enable host networking/);
  assert.match(linux, /Raspberry Pi/);
  assert.match(manifest, /Transaction semantics/);
  assert.match(security, /Security model/);
  assert.match(contributing, /Keep Bridge application-neutral/);
});
