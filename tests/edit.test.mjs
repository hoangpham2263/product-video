import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { PWSH, psFile, toolEnv } from "../core/platform.mjs";

// src/edit.ps1 is checked by tests/edit.tests.ps1 (it runs on its own too); here it runs under
// the same PowerShell the app uses, and every failed check shows in the message.
const script = fileURLToPath(new URL("./edit.tests.ps1", import.meta.url));

test("edit.ps1: music under a video (tests/edit.tests.ps1)", async () => {
  const { code, out } = await new Promise((done) => execFile(PWSH, psFile(script), { env: toolEnv, timeout: 120000, windowsHide: true },
    (err, stdout, stderr) => done({ code: err ? err.code ?? 1 : 0, out: `${stdout}${stderr}` })));
  assert.equal(code, 0, out.split(/\r?\n/).filter((l) => !l.startsWith("ok ")).join("\n"));
  assert.match(out, /all checks passed/);
});
