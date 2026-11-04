// The app window on macOS (core/platform.mjs appWindow): Chrome for Testing in workspace/browser with a
// profile of its own (workspace/browser/app), so a tool opens as an app window (no tabs or address bar); not downloaded,
// the user's Chrome shows them. The AIs (Flow, Gemini, ChatGPT) run in the user's own Chrome through the Product Video
// extension (core/extension, core/bridge), not here.
//   node core/browser.mjs download   download it (about 150 MB), once
//   node core/browser.mjs status     { installed }
// Prints one JSON line.
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const dir = join(root, "workspace", "browser");
const platform = { darwin: process.arch === "arm64" ? "mac-arm64" : "mac-x64", win32: process.arch === "ia32" ? "win32" : "win64" }[process.platform] || "linux64";
export const executable = join(dir, `chrome-${platform}`, ...(platform.startsWith("mac")
  ? ["Google Chrome for Testing.app", "Contents", "MacOS", "Google Chrome for Testing"]
  : [platform.startsWith("win") ? "chrome.exe" : "chrome"]));
export const appProfile = join(dir, "app");

const run = (cmd, args) => new Promise((done, fail) => execFile(cmd, args, { windowsHide: true, maxBuffer: 1 << 24 }, (err) => (err ? fail(err) : done())));

// The newest Chrome for Testing that Google lists as good, about 150 MB; unpacked once.
async function download() {
  const index = await fetch("https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json").then((r) => r.json());
  const url = index.channels.Stable.downloads.chrome.find((d) => d.platform === platform)?.url;
  if (!url) throw new Error(`Chưa có Chrome cho máy này (${platform}).`);
  mkdirSync(dir, { recursive: true });
  const zip = join(dir, "chrome.zip");
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Tải Chrome lỗi ${response.status}.`);
  writeFileSync(zip, Buffer.from(await response.arrayBuffer()));
  rmSync(join(dir, `chrome-${platform}`), { recursive: true, force: true });
  // ditto keeps the app bundle's links on macOS; Windows 10+ has tar for zip files.
  if (platform.startsWith("mac")) await run("ditto", ["-x", "-k", zip, dir]);
  else await run("tar", ["-xf", zip, "-C", dir]);
  rmSync(zip, { force: true });
  if (!existsSync(executable)) throw new Error("Giải nén Chrome không thành công.");
}

async function main(command) {
  if (command === "status") return { installed: existsSync(executable) };
  if (command === "download") { if (!existsSync(executable)) await download(); return { ok: true }; }
  throw new Error("Lệnh: download | status");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv[2]).then((r) => console.log(JSON.stringify(r)), (e) => { console.log(JSON.stringify({ error: e.message })); process.exitCode = 1; });
}
