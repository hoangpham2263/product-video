// Product Video's window (ui/) served on localhost, on macOS and Windows alike, and the run it starts (src/run-video.ps1).
// core/launch.ps1 starts this file with --no-open and finds it by /api/root; each install gets its own port from its
// folder. The run prints @@EVENT lines; they become the events the window polls.
import { createServer } from "node:http";
import { spawn, execFile } from "node:child_process";
import { createInterface } from "node:readline";
import { mkdir, writeFile, appendFile, readFile, readdir } from "node:fs/promises";
import { createReadStream, existsSync, mkdirSync, openSync, readFileSync, statSync, renameSync, appendFileSync } from "node:fs";
import { join, dirname, extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID, createHash } from "node:crypto";
import { createConfigApi } from "../core/setup/config-api.mjs";
import { PWSH, toolEnv, psFile, psCommand, killTree, appWindow, onWindows } from "../core/platform.mjs";
import { createLibrary, SOURCES_URL } from "./library.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const BASE_PORT = Number(process.env.GV_PORT || 47000 + (parseInt(createHash("sha1").update(root).digest("hex").slice(0, 6), 16) % 1000));
let PORT = BASE_PORT;
const workspace = join(root, "workspace");
const logs = join(workspace, "logs");
const uploads = join(workspace, "temp", "uploads");
const configApi = createConfigApi({ hubRoot: root, pwsh: PWSH, env: toolEnv });
const library = createLibrary({ workspace });
mkdirSync(logs, { recursive: true });

const logFile = (name) => {
  const file = join(logs, name);
  try { if (statSync(file).size > 1024 * 1024) renameSync(file, file.replace(/\.log$/, ".old.log")); } catch {}
  return file;
};
const logError = (where, text) => {
  try { appendFileSync(logFile("app-errors.log"), `[${new Date().toISOString()}] ${where}\n  ${String(text).trim().replace(/\n/g, "\n  ")}\n\n`); } catch {}
};
process.on("uncaughtException", (e) => { logError("Máy chủ Product Video", e.stack || e); process.exit(1); });
process.on("unhandledRejection", (e) => logError("Máy chủ Product Video", e?.stack || e));

const TYPES = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".mp4": "video/mp4", ".mov": "video/quicktime", ".webm": "video/webm", ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".aac": "audio/aac", ".wav": "audio/wav" };
const IMAGE_EXT = [".png", ".jpg", ".jpeg", ".webp"];
const AUDIO_EXT = [".mp3", ".m4a", ".aac", ".wav"];
const SERVED_EXT = [...IMAGE_EXT, ".mp4", ".mov", ".webm", ...AUDIO_EXT];
const CORE_ASSETS = ["tool.css", "hub.js"];

const readJson = async (file) => JSON.parse((await readFile(file, "utf8")).replace(/^﻿/, ""));
const pageData = async () => {
  const angles = await readJson(join(root, "data", "angles.json"));
  const settings = Object.assign(await readJson(join(root, "data", "video.json")), await readChoices());
  return {
    settings, samples: `${process.env.PV_SOURCES_URL || SOURCES_URL}/samples`,
    angles: { groups: angles.groups, list: angles.angles.map(({ id, label, group, description }) => ({ id, label, group, description })) },
  };
};

// ----- Lựa chọn: the transitions and angles the user switched off -----
// Kept in workspace/lua-chon.json { bannedTransitions, bannedAngles } (an update keeps workspace/); a list not saved yet
// is data/video.json's. src/plan.ps1 reads the same file. The Hiệu ứng and Góc máy pages send one switch at a time
// ({ list, id, off }), applied here to the list as it is now: a page open for long cannot write back an old list
// (04/11/2026 one did, and turned zoomin back on).
const choicesFile = join(workspace, "lua-chon.json");
const readChoices = async () => (existsSync(choicesFile) ? await readJson(choicesFile) : {});
async function saveChoice({ list, id, off }) {
  const settings = await readJson(join(root, "data", "video.json"));
  const known = list === "bannedTransitions" ? settings.transitionNames
    : list === "bannedAngles" ? (await readJson(join(root, "data", "angles.json"))).angles.map((a) => a.id) : null;
  if (!known) throw new Error("Danh sách không hợp lệ.");
  if (!known.includes(String(id))) throw new Error(`Không có: ${id}.`);
  const choices = await readChoices();
  const now = new Set([].concat(choices[list] ?? settings[list] ?? []).map(String));
  off ? now.add(String(id)) : now.delete(String(id));
  choices[list] = [...now].filter((n) => known.includes(n));
  await writeFile(choicesFile, JSON.stringify(choices, null, 2) + "\n", "utf8");
  return { [list]: choices[list] };
}

// ----- Phân tích video mẫu -----
// src/analyze-reference.ps1 reads a sample the way the run does (plan.ps1) and prints @@RESULT { shots, ... }; its
// frames go to workspace/temp/analyze/<hash of the path>/. Lưu writes the plan beside the video as <video>.json (only a
// video under workspace/), the shape the library uses: { note?, shots: [{ start, angle }] }.
const VIDEO_EXT = [".mp4", ".mov", ".webm"];
const libraryRoot = join(workspace, "library");
let analyzing = false;
async function libraryVideos(dir = libraryRoot, out = []) {
  for (const e of await readdir(dir, { withFileTypes: true }).catch(() => [])) {
    const full = join(dir, e.name);
    if (e.isDirectory()) await libraryVideos(full, out);
    else if (VIDEO_EXT.includes(extname(e.name).toLowerCase())) out.push({ path: full, name: full.slice(libraryRoot.length + 1).replace(/\\/g, "/"), plan: existsSync(`${full}.json`) });
  }
  return out;
}
function analyze(video) {
  const outDir = join(workspace, "temp", "analyze", createHash("sha1").update(video).digest("hex").slice(0, 12));
  return new Promise((done, fail) => execFile(PWSH, psFile(join(root, "src", "analyze-reference.ps1"), ["-Video", video, "-OutDir", outDir]), { cwd: root, env: toolEnv, timeout: 600000, windowsHide: true, maxBuffer: 16 * 1024 * 1024 }, (err, out, errOut) => {
    const line = String(out).split(/\r?\n/).find((l) => l.startsWith("@@RESULT "));
    if (line) { try { return done(JSON.parse(line.slice(9))); } catch {} }
    logError("Phân tích video mẫu", `${err?.message || ""}\n${errOut || ""}`);
    fail(new Error(String(errOut || err?.message || "Không phân tích được.").trim().split("\n")[0].slice(0, 300)));
  }));
}
async function savePlan({ video, note, shots }) {
  const file = resolve(String(video || ""));
  if (!file.startsWith(workspace + sep) || !VIDEO_EXT.includes(extname(file).toLowerCase()) || !existsSync(file)) throw new Error("Chỉ lưu được kế hoạch cho video trong workspace/.");
  const ids = (await readJson(join(root, "data", "angles.json"))).angles.map((a) => a.id);
  const list = [].concat(shots || []).map((s) => ({ start: Math.round(Number(s?.start) * 100) / 100, angle: String(s?.angle) }));
  if (!list.length) throw new Error("Chưa có cảnh nào.");
  for (const s of list) {
    if (!Number.isFinite(s.start) || s.start < 0) throw new Error("Thời điểm bắt đầu của cảnh không hợp lệ.");
    if (!ids.includes(s.angle)) throw new Error(`Góc lạ: ${s.angle}.`);
  }
  list.sort((a, b) => a.start - b.start);
  list[0].start = 0;
  const text = String(note || "").trim();
  // Written like the library's own plans: one shot per line.
  const json = `{\n${text ? `  "note": ${JSON.stringify(text)},\n` : ""}  "shots": [\n${list.map((s) => `    { "start": ${s.start}, "angle": ${JSON.stringify(s.angle)} }`).join(",\n")}\n  ]\n}\n`;
  await writeFile(`${file}.json`, json, "utf8");
  return { path: `${file}.json`, plan: JSON.parse(json) };
}

// ----- The run -----
const run = { proc: null, events: [], stopped: false, exitCode: null, done: false, folder: "", logFile: "" };
function receive(line) {
  if (!line.startsWith("@@EVENT ")) return;
  try {
    const event = JSON.parse(line.slice(8));
    if (event.kind === "start") run.folder = event.folder;
    run.events.push(event);
  } catch {}
}
async function startRun(job) {
  if (run.proc) throw new Error("Đang chạy.");
  if (!job?.photo) throw new Error("Chưa có ảnh sản phẩm.");
  await mkdir(join(workspace, "temp"), { recursive: true });
  const stamp = Date.now();
  const jobFile = join(workspace, "temp", `job-${stamp}.json`);
  await writeFile(jobFile, JSON.stringify(job), "utf8");
  Object.assign(run, { events: [], stopped: false, exitCode: null, done: false, folder: "", logFile: join(logs, `run-${stamp}.log`) });
  // Own process group (macOS), so Dừng stops the AI processes it started too.
  const proc = spawn(PWSH, psFile(join(root, "src", "run-video.ps1"), ["-JobFile", jobFile]), { cwd: root, env: toolEnv, detached: process.platform !== "win32", windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
  run.proc = proc;
  let tail = "";
  let chain = Promise.resolve();
  for (const stream of [proc.stdout, proc.stderr]) {
    createInterface({ input: stream }).on("line", (line) => {
      if (stream === proc.stderr) tail = (tail + "\n" + line).slice(-1500);
      chain = chain.then(() => appendFile(run.logFile, line + "\n")).then(() => receive(line));
    });
  }
  proc.on("error", (e) => { run.events.push({ kind: "fatal", message: e.message }); });
  proc.on("exit", (code) => {
    chain = chain.then(() => {
      run.exitCode = code;
      // A run that stopped before it said anything leaves its reason in stderr; the first line is the message.
      if (code && !run.events.some((e) => e.kind === "done" || e.kind === "fatal") && !run.stopped) run.events.push({ kind: "fatal", message: tail.trim().split("\n")[0].trim().slice(0, 300) || `PowerShell thoát với mã ${code}.` });
      run.proc = null;
      run.done = true;
    });
  });
}
const stopRun = () => { if (run.proc) { run.stopped = true; killTree(run.proc); } };

// ----- HTTP -----
const send = (res, status, data) => { res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }); res.end(JSON.stringify(data)); };
const body = async (req, limit = 300 * 1024 * 1024) => {
  const chunks = []; let size = 0;
  for await (const c of req) { size += c.length; if (size > limit) throw new Error("Tệp quá lớn."); chunks.push(c); }
  return Buffer.concat(chunks);
};
// Files with Range support: the video player seeks by asking for parts of the MP4.
const sendFile = (req, res, file) => {
  if (!existsSync(file) || !statSync(file).isFile()) { res.writeHead(404); return res.end(); }
  const size = statSync(file).size;
  const type = TYPES[extname(file).toLowerCase()] || "application/octet-stream";
  const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || "");
  if (range && (range[1] || range[2])) {
    const start = range[1] ? Number(range[1]) : Math.max(0, size - Number(range[2]));
    const end = range[1] && range[2] ? Math.min(Number(range[2]), size - 1) : size - 1;
    if (start >= size || start > end) { res.writeHead(416, { "content-range": `bytes */${size}` }); return res.end(); }
    res.writeHead(206, { "content-type": type, "content-length": end - start + 1, "content-range": `bytes ${start}-${end}/${size}`, "accept-ranges": "bytes", "cache-control": "no-store" });
    return createReadStream(file, { start, end }).pipe(res);
  }
  res.writeHead(200, { "content-type": type, "content-length": size, "accept-ranges": "bytes", "cache-control": "no-store" });
  createReadStream(file).pipe(res);
};
// Only what this tool wrote (its uploads and results) is served back to the window.
const allowedFile = (p) => { const full = resolve(p); return full.startsWith(workspace + sep) && SERVED_EXT.includes(extname(full).toLowerCase()); };
// Giao diện: what the window last showed (page, filters, the job's boxes and settings, the video being analysed), in
// workspace/giao-dien.json so it outlives a change of port. Stamped with the source in use (the release of a ZIP
// install, else the git commit): new source starts from a clean window (user, 05/11/2026). lua-chon.json is not part
// of it and stays.
const uiStateFile = join(workspace, "giao-dien.json");
function sourceStamp() {
  const v = version();
  if (v) return v;
  try {
    const head = readFileSync(join(root, ".git", "HEAD"), "utf8").trim();
    if (!head.startsWith("ref: ")) return head;
    const ref = head.slice(5);
    const loose = join(root, ".git", ref);
    if (existsSync(loose)) return readFileSync(loose, "utf8").trim();
    const packed = readFileSync(join(root, ".git", "packed-refs"), "utf8").split("\n").find((l) => l.endsWith(` ${ref}`));
    return packed ? packed.split(" ")[0] : "";
  } catch { return ""; }
}
const version = () => { try { return readFileSync(join(root, "workspace", "version.txt"), "utf8").trim(); } catch { return ""; } };
const q = (p) => p.replace(/'/g, "''");
const pwshOut = (command, timeout) => new Promise((done, fail) => execFile(PWSH, psCommand(command), { cwd: root, env: toolEnv, timeout, windowsHide: true }, (err, out) => (err ? fail(err) : done(String(out).trim()))));

function restart() {
  const out = openSync(logFile("server.log"), "a");
  spawn(process.execPath, [join(here, "server.mjs"), "--no-open"], { cwd: root, detached: true, windowsHide: true, stdio: ["ignore", out, out], env: { ...process.env, GV_WAIT_PORT: "1" } }).unref();
  setTimeout(() => process.exit(0), 300);
}

async function handle(req, res) {
  const url = new URL(req.url, "http://localhost");
  const path = url.pathname;
  if (path === "/api/root") return send(res, 200, { root, service: "product-video", protocol: 1, version: version(), pid: process.pid });
  if (path === "/api/data") return send(res, 200, await pageData());
  if (path === "/api/client-error" && req.method === "POST") {
    const { message = "", stack = "" } = JSON.parse((await body(req)).toString("utf8") || "{}");
    logError("Giao diện Product Video", [message, stack].filter(Boolean).join("\n").slice(0, 4000));
    return send(res, 200, { ok: true });
  }
  if (path === "/api/upload" && req.method === "POST") {
    // A picked or dropped photo, sample video or music track becomes a file the run reads (the window cannot hand PowerShell a blob).
    const name = (url.searchParams.get("name") || "image.png").replace(/[^\w.-]/g, "_");
    const ext = extname(name).toLowerCase();
    if (!SERVED_EXT.includes(ext)) return send(res, 400, { error: "Chọn ảnh PNG, JPEG, WebP, video MP4, MOV, WebM hoặc nhạc MP3, M4A, AAC, WAV." });
    await mkdir(uploads, { recursive: true });
    const file = join(uploads, `${randomUUID().replace(/-/g, "")}${ext}`);
    await writeFile(file, await body(req));
    return send(res, 200, { path: file });
  }
  if (path === "/api/analyze/videos" && req.method === "GET") return send(res, 200, { videos: await libraryVideos() });
  if (path === "/api/analyze" && req.method === "POST") {
    const { video = "" } = JSON.parse((await body(req)).toString("utf8") || "{}");
    const file = video && resolve(String(video));
    if (!file || !VIDEO_EXT.includes(extname(file).toLowerCase()) || !existsSync(file)) return send(res, 400, { error: "Chưa chọn video mẫu." });
    if (analyzing) return send(res, 409, { error: "Đang phân tích một video khác." });
    analyzing = true;
    try { const r = await analyze(file); return send(res, r.ok ? 200 : 400, r); }
    catch (e) { return send(res, 500, { error: e.message }); }
    finally { analyzing = false; }
  }
  if (path === "/api/analyze/save" && req.method === "POST") {
    try { return send(res, 200, await savePlan(JSON.parse((await body(req)).toString("utf8") || "{}"))); }
    catch (e) { return send(res, 400, { error: e.message }); }
  }
  if (path === "/api/ui-state" && req.method === "GET") {
    const saved = existsSync(uiStateFile) ? await readJson(uiStateFile).catch(() => ({})) : {};
    return send(res, 200, saved.stamp === sourceStamp() ? saved.state || {} : {});
  }
  if (path === "/api/ui-state" && req.method === "POST") {
    try {
      const state = JSON.parse((await body(req)).toString("utf8") || "{}");
      await writeFile(uiStateFile, JSON.stringify({ stamp: sourceStamp(), state }, null, 2) + "\n", "utf8");
      return send(res, 200, { ok: true });
    } catch (e) { return send(res, 400, { error: e.message }); }
  }
  if (path === "/api/choices" && req.method === "POST") {
    try { return send(res, 200, await saveChoice(JSON.parse((await body(req)).toString("utf8") || "{}"))); }
    catch (e) { return send(res, 400, { error: e.message }); }
  }
  if (path === "/api/run" && req.method === "POST") {
    try { await startRun(JSON.parse((await body(req)).toString("utf8") || "{}")); return send(res, 200, { ok: true }); }
    catch (e) { return send(res, 400, { error: e.message }); }
  }
  if (path === "/api/run" && req.method === "GET") {
    const since = Number(url.searchParams.get("since") || 0);
    return send(res, 200, { running: !!run.proc, done: run.done, exitCode: run.exitCode, stopped: run.stopped, folder: run.folder, events: run.events.slice(since), next: run.events.length });
  }
  if (path === "/api/stop" && req.method === "POST") { stopRun(); return send(res, 200, { ok: true }); }
  if (path === "/api/open-folder" && req.method === "POST") {
    const folder = run.folder && resolve(run.folder);
    if (!folder || !folder.startsWith(workspace + sep) || !existsSync(folder)) return send(res, 404, { error: "Chưa có thư mục kết quả." });
    spawn(onWindows ? "explorer.exe" : "open", [folder], { detached: true, stdio: "ignore" }).unref();
    return send(res, 200, { ok: true });
  }
  if (path === "/file") {
    const file = url.searchParams.get("path") || "";
    return allowedFile(file) ? sendFile(req, res, resolve(file)) : (res.writeHead(404), res.end());
  }
  // Kho ảnh: the groups of product-video-sources, and a picked photo saved for the run.
  if (await library(req, res, path, url)) return;
  // Cập nhật, Cấu hình, Tải lại (core/assets/hub.js).
  if (await configApi(req, res, path)) return;
  if (path === "/api/update-check") {
    const out = await pwshOut(`. '${q(join(root, "core", "update.ps1"))}' -NoRun; [pscustomobject]@{ current = (Get-InstalledVersion '${q(root)}'); next = (Get-AppUpdate '${q(root)}') } | ConvertTo-Json -Compress`, 60000).catch(() => "");
    res.writeHead(out ? 200 : 502, { "content-type": TYPES[".json"] });
    return res.end(out || "{}");
  }
  if (path === "/api/update" && req.method === "POST") {
    if (run.proc) return send(res, 409, { error: "Đang chạy. Dừng hoặc chờ xong rồi cập nhật." });
    const ok = await pwshOut(`. '${q(join(root, "core", "update.ps1"))}' -NoRun; Update-App '${q(root)}'`, 300000).then(() => true, () => false);
    send(res, ok ? 200 : 500, { ok });
    if (ok) setTimeout(() => { server.close(); restart(); }, 300);
    return;
  }
  if (path === "/api/reload" && req.method === "POST") {
    if (run.proc) return send(res, 409, { error: "Đang chạy. Dừng hoặc chờ xong rồi tải lại." });
    send(res, 200, { ok: true });
    setTimeout(() => { server.close(); restart(); }, 300);
    return;
  }
  if (path === "/api/quit" && req.method === "POST") { send(res, 200, { ok: true }); stopRun(); setTimeout(() => process.exit(0), 200); return; }
  if (path === "/icon.svg") return sendFile(req, res, join(root, "icon.svg"));
  const asset = /^\/core\/assets\/([\w.-]+)$/.exec(path);
  if (asset) return CORE_ASSETS.includes(asset[1]) ? sendFile(req, res, join(root, "core", "assets", asset[1])) : (res.writeHead(404), res.end());
  const rel = path === "/" ? "index.html" : path.slice(1);
  const file = resolve(root, "ui", rel);
  if (!file.startsWith(resolve(root, "ui") + sep)) { res.writeHead(404); return res.end(); }
  return sendFile(req, res, file);
}

const server = createServer((req, res) => handle(req, res).catch((e) => send(res, 500, { error: e.message })));
function listen(attempt = 0) {
  server.once("error", (e) => {
    // The old server is still closing after an update or a reload.
    if (e.code === "EADDRINUSE" && process.env.GV_WAIT_PORT && attempt < 50) return setTimeout(() => listen(attempt + 1), 200);
    if (e.code === "EADDRINUSE") {
      // Already running for this folder: just show it. Another program on the port: try the next one.
      return fetch(`http://127.0.0.1:${PORT}/api/root`).then((r) => r.json()).then((info) => {
        if (info.root !== root) throw new Error("other");
        if (!process.argv.includes("--no-open")) appWindow(`http://127.0.0.1:${PORT}/`);
        process.exit(0);
      }).catch(() => {
        if (PORT - BASE_PORT >= 20) throw e;
        PORT++;
        listen(attempt);
      });
    }
    throw e;
  });
  server.listen(PORT, "127.0.0.1", () => { if (!process.argv.includes("--no-open")) appWindow(`http://127.0.0.1:${PORT}/`); });
}
listen();
