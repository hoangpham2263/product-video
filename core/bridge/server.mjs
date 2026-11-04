// Local bridge, shared by every tool: a tool POSTs a job over HTTP, the Product Video extension (core/extension, in the
// user's own Chrome) receives it over WebSocket. ensure.mjs starts it and waits for the extension.
// Jobs from every tool and thread go to the extension side by side, each in a tab of its own: up to `parallel` at once
// (the most threads a tool runs), and per site up to `perSite` (Flow side by side; Gemini, which Google sends to its
// "unusual traffic" page when several chats open at once, and ChatGPT one at a time). More wait their turn, at most
// queueMs. A job's own time (timeoutSec) starts when it is sent.
// Listens on 127.0.0.1 only; nothing is exposed to the network.
import { createServer } from "node:http";
import { appendFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { WebSocketServer } from "ws";

export const PORT = Number(process.env.BRIDGE_PORT || 8785);
const MIME = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp" };

// The Google account chosen on Cấu hình for Flow and Gemini (workspace/config/google-account.json); "" is Google's
// default, the first one signed in.
const hubConfig = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "workspace", "config", "google-account.json");
const chosenGoogleAccount = () => { try { return String(JSON.parse(readFileSync(hubConfig, "utf8")).email || ""); } catch { return ""; } };

// When this file was last changed, as the running bridge loaded it: after an update the app sees an older one and
// restarts it (POST /quit; ensure.mjs).
// Which file that is: ensure.mjs of another copy of the app (a git checkout, its tests) leaves it running.
const serverFile = fileURLToPath(import.meta.url);
const code = Math.floor(statSync(serverFile).mtimeMs);

// What the extension reports while it works, with the time: workspace/logs/bridge.log (started again once over
// 1 MB), as the bridge runs detached with no output of its own.
const logFile = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "workspace", "logs", "bridge.log");
function log(line) {
  try {
    mkdirSync(dirname(logFile), { recursive: true });
    const text = `${new Date().toISOString()} ${line}\n`;
    if (existsSync(logFile) && statSync(logFile).size > 1 << 20) writeFileSync(logFile, text); else appendFileSync(logFile, text);
  } catch {}
}

// Every job the extension ran, one JSON line in workspace/logs/ai-usage.jsonl, beside the CLI calls core/ai
// records (Cấu hình → Lượt dùng AI): with the account it ran with and, when it failed, what stopped it.
const usageFile = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "workspace", "logs", "ai-usage.jsonl");
const KIND = { gemini: "text", flow: "image", chatgpt: "image", grok: "image" };
export function causeOf(error) {
  const text = String(error || "");
  if (/chính sách|polic(y|ies)|từ chối tạo|kiểm duyệt|moderat/i.test(text)) return "POLICY";
  if (/quota|limit|hết lượt|giới hạn|429|too many/i.test(text)) return "QUOTA";
  if (/Hết thời gian|timeout/i.test(text)) return "AI_TIMEOUT";
  if (/đăng nhập|sign.?in|log.?in/i.test(text)) return "AUTH";
  if (/Extension|Google Flow của tài khoản đang chọn/i.test(text)) return "BRIDGE";
  return "BUSY";
}

export function createBridge({ fetchImpl = fetch, googleAccount = chosenGoogleAccount, quit = () => process.exit(0), queueMs = 30 * 60000, usage = usageFile, parallel = 4, perSite = { flow: 4, gemini: 1, chatgpt: 1, grok: 1 } } = {}) {
  const record = (entry) => { try { mkdirSync(dirname(usage), { recursive: true }); appendFileSync(usage, JSON.stringify({ t: new Date().toISOString(), ...entry }) + "\n"); } catch {} };
  let extension = null, extensionVersion = "";
  const pending = new Map();
  // Jobs waiting to be sent, and how many are with the extension now.
  const waiting = [];
  let running = 0;
  const bySite = {};
  const jobs = () => waiting.length + running;
  function next() {
    for (let i = 0; running < parallel && i < waiting.length; i++) {
      const item = waiting[i];
      if ((bySite[item.site] || 0) >= (perSite[item.site] ?? parallel)) continue;
      waiting.splice(i--, 1);
      clearTimeout(item.timer);
      running++;
      bySite[item.site] = (bySite[item.site] || 0) + 1;
      item.run().then(item.resolve, item.reject).finally(() => { running--; bySite[item.site]--; next(); });
    }
  }
  const inTurn = (site, run) => new Promise((resolve, reject) => {
    const item = { site, run, resolve, reject };
    item.timer = setTimeout(() => { waiting.splice(waiting.indexOf(item), 1); reject(new Error("queue")); }, queueMs);
    waiting.push(item);
    next();
  });
  // One message to the extension and its answer ({ type: "result", id, ok, ... }).
  const ask = (message, ms) => new Promise((resolve, reject) => {
    const id = message.id || randomUUID();
    const timer = setTimeout(() => { pending.delete(id); reject(new Error("timeout")); }, ms);
    timer.unref?.();
    pending.set(id, { resolve, timer });
    extension.send(JSON.stringify({ ...message, id }));
  });

  const server = createServer(async (req, res) => {
    const send = (status, body) => { res.writeHead(status, { "content-type": "application/json; charset=utf-8" }); res.end(JSON.stringify(body)); };
    try {
      if (req.method === "GET" && req.url === "/status") return send(200, { extension: !!extension, extensionVersion: extension ? extensionVersion : "", code, server: serverFile, pid: process.pid, jobs: jobs() });
      if (req.method === "POST" && req.url === "/quit") { send(200, { ok: true }); return setTimeout(quit, 100); }
      if (req.method === "POST" && req.url === "/reload") {
        if (!extension) return send(503, { error: "Extension chưa kết nối." });
        extension.send(JSON.stringify({ type: "reload" }));
        return send(200, { ok: true });
      }
      // Who is signed in to Google (Flow, Gemini) and ChatGPT in that Chrome, read by the extension: Cấu hình.
      if (req.method === "GET" && req.url === "/logins") {
        if (!extension) return send(503, { error: "Extension chưa kết nối." });
        const result = await ask({ type: "logins" }, 20000);
        return send(result.ok ? 200 : 502, result.ok ? { google: !!result.google, accounts: result.accounts || [], chatgpt: !!result.chatgpt } : { error: result.error });
      }
      // A page the tools open (Cấu hình: sign-in pages, Flow, Gemini), shown in the Product Video tab group: POST { url }.
      if (req.method === "POST" && req.url === "/open") {
        if (!extension) return send(503, { error: "Extension chưa kết nối." });
        let raw = "";
        for await (const chunk of req) raw += chunk;
        const url = String(JSON.parse(raw || "{}").url || "");
        if (!/^(https:\/\/|chrome:\/\/extensions)/.test(url)) return send(400, { error: "url must be https:// or chrome://extensions" });
        const result = await ask({ type: "open", url }, 15000);
        return send(result.ok ? 200 : 502, result.ok ? { ok: true } : { error: result.error });
      }
      // A run starts: the Product Video group's tabs are closed, so the run has only its own. Not while another tool's job
      // waits or runs (skipped: busy).
      if (req.method === "POST" && req.url === "/session") {
        if (!extension) return send(503, { error: "Extension chưa kết nối." });
        if (jobs()) return send(200, { ok: true, skipped: "busy" });
        const result = await ask({ type: "session" }, 15000);
        log(`session: ${result.ok ? `closed ${result.closed} tabs` : `error: ${result.error}`}`);
        return send(result.ok ? 200 : 502, result.ok ? { ok: true, closed: result.closed } : { error: result.error });
      }
      if (req.method !== "POST" || req.url !== "/generate") return send(404, { error: "not found" });
      let raw = "";
      for await (const chunk of req) raw += chunk;
      const job = JSON.parse(raw);
      if (!["chatgpt", "flow", "gemini", "grok"].includes(job.platform)) return send(400, { error: "platform must be chatgpt, flow, gemini or grok" });
      if (!job.prompt || !job.output) return send(400, { error: "prompt and output are required" });
      if (!extension) return send(503, { error: "Extension chưa kết nối. Mở Chrome có cài extension Product Video." });
      const images = await Promise.all((job.images || []).map(async (path, index) => ({
        name: `ref-${index + 1}${extname(path).toLowerCase()}`,
        mime: MIME[extname(path).toLowerCase()] || "application/octet-stream",
        data: (await readFile(path)).toString("base64"),
      })));
      const timeoutSec = Number(job.timeoutSec || 600);
      // Grok (grok.com, its own sign-in) and ChatGPT run with whoever is signed in there.
      const account = ["chatgpt", "grok"].includes(job.platform) ? "" : googleAccount();
      // Grok makes images and videos: the job says which (kind) and how (options: seconds, resolution, audio).
      const kind = String(job.kind || KIND[job.platform]);
      const id = randomUUID();
      const result = await inTurn(job.platform, async () => {
        if (!extension) return { ok: false, error: "Extension chưa kết nối. Mở Chrome có cài extension Product Video." };
        log(`[${id.slice(0, 8)}] ${job.platform} job sent (${running} running)`);
        const started = Date.now();
        const done = await ask({ type: "generate", id, platform: job.platform, kind, options: job.options || {}, prompt: job.prompt, images, timeoutSec, account }, (timeoutSec + 60) * 1000)
          .catch((error) => ({ ok: false, error: error.message === "timeout" ? `Hết thời gian chờ (${timeoutSec + 60}s)` : String(error.message || error), thrown: error }));
        record({ ai: job.platform, kind, account, ok: !!done.ok, ...(done.ok ? {} : { cause: causeOf(done.error) }), ms: Date.now() - started });
        if (done.thrown) throw done.thrown;
        return done;
      });
      if (!result.ok) return send(502, { error: result.error });
      // Text replies (Gemini) are written as UTF-8 text.
      if (typeof result.text === "string") {
        await writeFile(job.output, result.text, "utf8");
        return send(200, { ok: true, output: job.output, chars: result.text.length, source: result.source || "" });
      }
      let bytes;
      if (result.data) bytes = Buffer.from(result.data, "base64");
      else {
        const response = await fetchImpl(result.url);
        if (!response.ok) return send(502, { error: `download ${response.status}` });
        bytes = Buffer.from(await response.arrayBuffer());
      }
      await writeFile(job.output, bytes);
      return send(200, { ok: true, output: job.output, bytes: bytes.length, source: result.source || "" });
    } catch (error) {
      if (error.message === "queue") return send(504, { error: `Hết thời gian chờ đến lượt (${Math.round(queueMs / 60000)} phút): các việc trước vẫn đang chạy trong Chrome.` });
      return send(error.message === "timeout" ? 504 : 500, { error: String(error.message || error) });
    }
  });

  const sockets = new WebSocketServer({ server });
  sockets.on("connection", (socket, req) => {
    // Only the Chrome extension may attach; web pages cannot spoof this origin.
    if (!String(req.headers.origin || "").startsWith("chrome-extension://")) return socket.close();
    extension = socket;
    socket.on("message", (data) => {
      let message;
      try { message = JSON.parse(data); } catch { return; }
      if (message.type === "hello") extensionVersion = String(message.version || "");
      if (message.type === "progress") log(`[${String(message.id).slice(0, 8)}] ${message.stage}`);
      if (message.type === "result" && pending.has(message.id)) {
        const { resolve, timer } = pending.get(message.id);
        clearTimeout(timer);
        pending.delete(message.id);
        if (message.type === "result" && !message.ok) log(`[${message.id.slice(0, 8)}] error: ${message.error}`);
        resolve(message);
      }
    });
    socket.on("close", () => { if (extension === socket) extension = null; });
  });
  return server;
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("server.mjs")) {
  // Why a bridge stopped mid-run, kept across restarts: workspace/logs/bridge-exit.log.
  const exitLog = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "workspace", "logs", "bridge-exit.log");
  const note = (text) => { try { mkdirSync(dirname(exitLog), { recursive: true }); appendFileSync(exitLog, `${new Date().toISOString()} pid ${process.pid} ${text}\n`); } catch {} };
  // Started by an older run, its output can be that run's pipe, closed once the run ends: a later line must not stop it (EPIPE).
  for (const stream of [process.stdout, process.stderr]) stream.on("error", () => {});
  process.on("uncaughtException", (error) => { note(`crash: ${error?.stack || error}`); process.exit(1); });
  process.on("unhandledRejection", (error) => note(`unhandled rejection: ${error?.stack || error}`));
  for (const signal of ["SIGTERM", "SIGHUP", "SIGINT"]) process.on(signal, () => { note(`stopped by ${signal}`); process.exit(0); });
  createBridge().listen(PORT, "127.0.0.1", () => console.log(`Bridge ready on http://127.0.0.1:${PORT}`));
}
