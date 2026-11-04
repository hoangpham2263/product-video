// Gets the bridge (server.mjs) and the Product Video extension ready for a tool, and prints one JSON line:
//   node core/bridge/ensure.mjs [--logins] [--no-open] [--open <url>] [--session]
//   { ok, extension, version[, logins: { google, accounts, chatgpt }][, opened][, closed] } or { error }
// --session: a run starts; the tabs of the Product Video group are closed first (not while another tool's job runs).
// --open: that page in Chrome, in the Product Video tab group (by the extension); without the extension, a plain new tab.
// The bridge is installed (npm, its one package ws) and started when missing, started again after Cập nhật changed
// server.mjs, and runs detached with no output of its own (a pipe of whoever started it would close: EPIPE). Without
// the extension connected, the user's Chrome is started (--no-open: not; Cấu hình only checks) and waited for; an
// extension of another version than core/extension/manifest.json is reloaded, so the new files load.
import { execFile, spawn } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { findTool, onWindows, openChrome, runTool, toolEnv } from "../platform.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const server = join(here, "server.mjs");
const BRIDGE = `http://127.0.0.1:${Number(process.env.BRIDGE_PORT || 8785)}`;
const NO_EXTENSION = `Chưa thấy extension Product Video trong Chrome. Cài một lần: mở chrome://extensions, bật Chế độ nhà phát triển, bấm Tải tiện ích đã giải nén, chọn thư mục ${join(here, "..", "extension")}.`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const get = (path, method = "GET", body) => fetch(BRIDGE + path, { method, body: body && JSON.stringify(body), signal: AbortSignal.timeout(["/logins", "/open", "/session"].includes(path) ? 25000 : 3000) }).then((r) => r.json()).catch(() => null);
const until = async (test, ms) => { for (const end = Date.now() + ms; Date.now() < end; await sleep(500)) { const s = await get("/status"); if (test(s)) return s; } return get("/status"); };

async function main(args) {
  // Test suites (TOOLS_HUB_TEST, tests/run.ps1) never start, stop or reload the bridge a run on this machine uses.
  if (process.env.TOOLS_HUB_TEST) return { ok: false, extension: false, error: "Bỏ qua bridge khi chạy test." };
  if (!existsSync(join(here, "node_modules", "ws"))) {
    const npm = findTool("npm");
    if (!npm) return { error: "Chưa cài Node.js (npm). Mở Cấu hình, bấm Cài." };
    await new Promise((done) => runTool(npm, ["install", "--silent", "--no-audit", "--no-fund"], { cwd: here, env: toolEnv, timeout: 5 * 60000, windowsHide: true }, done));
    if (!existsSync(join(here, "node_modules", "ws"))) return { error: "Chưa cài được bridge (npm install trong core/bridge). Kiểm tra mạng rồi chạy lại." };
  }
  let status = await get("/status");
  // A bridge of another copy of the app (a git checkout and its tests, beside the install) is left alone, and so is
  // its extension: replacing it would cut the jobs of a run there.
  const foreign = !!status?.server && resolve(status.server) !== resolve(server);
  // Started on an older server.mjs of this copy (or from a tool's own bridge/ before it moved to core/bridge, which
  // does not say its file): stop it first.
  if (status && !foreign && Number(status.code) !== Math.floor(statSync(server).mtimeMs)) {
    await get("/quit", "POST");
    status = await until((s) => !s, 5000);
    if (status && status.pid) { try { process.kill(status.pid); } catch {} status = await until((s) => !s, 5000); }
    if (status && !onWindows) { execFile("pkill", ["-f", "bridge/server.mjs"]); status = await until((s) => !s, 5000); }
    if (status) return { error: "Bridge cũ vẫn chạy ở cổng 8785. Khởi động lại máy rồi chạy lại." };
  }
  if (!status) {
    spawn(process.execPath, [server], { cwd: here, detached: true, stdio: "ignore", windowsHide: true }).unref();
    status = await until((s) => s, 10000);
    if (!status) return { error: "Không bật được bridge (core/bridge/server.mjs)." };
  }
  if (!status.extension) {
    // A Chrome already open connects within a few seconds (its extension wakes every 30 s at most).
    status = await until((s) => s?.extension, 4000);
    if (!status?.extension && !args.includes("--no-open")) {
      const error = await openChrome("", { background: true });
      if (error) return { error };
      status = await until((s) => s?.extension, 45000);
    }
    if (!status?.extension) {
      const page = args[args.indexOf("--open") + 1];
      if (args.includes("--open") && page) { const error = await openChrome(page); return error ? { error } : { ok: false, extension: false, opened: true, error: NO_EXTENSION }; }
      return { ok: false, extension: false, error: NO_EXTENSION };
    }
  }
  const version = String(JSON.parse(readFileSync(join(here, "..", "extension", "manifest.json"), "utf8")).version);
  if (!foreign && status.extensionVersion && status.extensionVersion !== version) {
    await get("/reload", "POST");
    status = await until((s) => s?.extension && s.extensionVersion === version, 20000);
  }
  const answer = { ok: true, extension: !!status?.extension, version: status?.extensionVersion || "", ...(foreign ? { foreign: status.server } : {}) };
  if (args.includes("--open")) {
    const page = args[args.indexOf("--open") + 1];
    const opened = await get("/open", "POST", { url: page });
    if (opened?.ok) answer.opened = true;
    else { const error = await openChrome(page); if (error) return { error }; answer.opened = true; }
  }
  if (args.includes("--session")) {
    const session = await get("/session", "POST");
    if (session?.ok) answer.closed = session.closed || 0;
  }
  if (args.includes("--logins")) {
    const logins = await get("/logins");
    if (logins && !logins.error) answer.logins = logins;
  }
  return answer;
}

main(process.argv.slice(2)).then((r) => console.log(JSON.stringify(r)), (e) => { console.log(JSON.stringify({ error: e.message })); process.exitCode = 1; });
