// Cấu hình, served by Product Review's server: the same steps and settings as core/setup/*.ps1, kept in
// workspace/config.
//   GET /setup[?back=<path>]        the Cấu hình page (page.html, page.js; tool.css from core/assets)
//   POST /api/setup                 the steps (setup-check.ps1 -AsJson)
//   POST /api/setup-step {step}     install: Codex and the bridge (core/bridge); login: codex login with a
//                                   one-time code, typed on the sign-in page opened in the user's Chrome;
//                                   browser: Chrome's extensions page and core/extension, to install the Product Review
//                                   extension; google: Google's account chooser in Chrome (sign in, add or switch);
//                                   site {site}: gemini, flow or chatgpt opened there; antigravity: a terminal
//                                   with agy, where /login (/logout first to switch) signs it in
//   GET /api/setup-login            { code } while a sign-in waits for it
//   GET|POST /api/config/ai         Model AI: { settings, models } / save { model, effort }
//   GET /api/usage                  Lượt dùng AI: { rows } per AI and account (usage.mjs)
//   GET|POST /api/config/google     the Google account Flow and Gemini run with: { email } / choose { email } ("" is
//                                   Google's default, the first one signed in)
import { execFile, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { findTool as findIn, runTool, psCommand, psFile, onWindows, killTree, openTerminal, openChrome } from "../platform.mjs";
import { createSetupReader } from "./setup-report.mjs";
import { readUsage, summarizeUsage } from "./usage.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const q = (p) => p.replace(/'/g, "''");

export function createConfigApi({ hubRoot, pwsh, env = process.env }) {
  const readSetup = createSetupReader({ hubRoot, pwsh, args: psFile(join(here, "setup-check.ps1"), ["-AsJson"]), env });
  const findTool = (name) => findIn(name, env);
  const json = (res, status, data) => { res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" }); res.end(JSON.stringify(data)); };
  const body = (req) => new Promise((done) => { const chunks = []; req.on("data", (c) => chunks.push(c)); req.on("end", () => { try { done(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}")); } catch { done({}); } }); });
  // A PowerShell command over the setup scripts; it prints one JSON line, errors included ({ error }).
  const ps = (script, extraEnv = {}) => new Promise((done) => {
    const command = `$ErrorActionPreference='Stop'; try { ${script} } catch { @{ error = $_.Exception.Message } | ConvertTo-Json -Compress }`;
    execFile(pwsh, psCommand(command), { cwd: hubRoot, env: { ...env, ...extraEnv }, timeout: 120000, windowsHide: true }, (err, stdout) => {
      try { done(JSON.parse(String(stdout).trim().split(/\r?\n/).pop())); } catch { done({ error: "Chưa đọc được cấu hình." }); }
    });
  });
  const load = (file) => `. '${q(join(here, file))}'`;
  // The chosen Google account (setup-check.ps1 shows it and drops it once it is no longer signed in; the browser bridge
  // opens Flow and Gemini with it).
  const googleFile = join(hubRoot, "workspace", "config", "google-account.json");
  const googleAccount = () => { try { return String(JSON.parse(readFileSync(googleFile, "utf8")).email || ""); } catch { return ""; } };
  const withAccount = (url) => (googleAccount() ? `${url}?authuser=${encodeURIComponent(googleAccount())}` : url);
  const workspace = q(join(hubRoot, "workspace"));
  // A page in the user's own Chrome, where the AIs are signed in: in the Product Review tab group, opened by the extension
  // (core/bridge/ensure.mjs --open; without the extension, a plain new tab).
  const openInChrome = (url, done) => execFile(process.execPath, [join(hubRoot, "core", "bridge", "ensure.mjs"), "--open", url], { cwd: hubRoot, env, timeout: 120000, windowsHide: true }, (err, stdout) => {
    let r = {}; try { r = JSON.parse(String(stdout).trim().split(/\r?\n/).pop()); } catch { r = { error: err?.message || "Không mở được Chrome." }; }
    done(r.opened ? { ok: true } : { error: r.error || "Không mở được Chrome." });
  });
  // codex login opens the system's default browser; with --device-auth it prints a page and a code instead, so the
  // page opens in Chrome and Cấu hình shows the code to type there.
  // Đăng nhập again while one waits: that one stops (its answer says so) and a new code comes.
  let loginCode = "", login = null;
  const codexLogin = (codex, done) => {
    if (login) { const old = login; login = null; loginCode = ""; killTree(old.child); old.done({ superseded: true }); }
    const child = spawn(onWindows && /\.cmd$/i.test(codex) ? `"${codex}"` : codex, ["login", "--device-auth"], { cwd: hubRoot, env, windowsHide: true, detached: !onWindows, shell: onWindows && /\.cmd$/i.test(codex) });
    const timer = setTimeout(() => killTree(child), 15 * 60000);
    let out = "", opened = false;
    login = { child, done };
    const current = () => login?.child === child;
    const read = (chunk) => {
      out = (out + chunk).replace(/\x1b\[[0-9;]*m/g, "");
      const url = out.match(/https:\/\/\S+\/device\b\S*/)?.[0], code = out.match(/\b[A-Z0-9]{4,}-[A-Z0-9]{4,}\b/)?.[0];
      if (opened || !url || !code || !current()) return;
      opened = true;
      loginCode = code;
      openInChrome(url, (r) => { if (r.error) { loginCode = ""; killTree(child); done({ error: r.error }); } });
    };
    child.stdout.on("data", read);
    child.stderr.on("data", read);
    child.on("error", (e) => { clearTimeout(timer); if (!current()) return; login = null; loginCode = ""; done({ error: e.message }); });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (!current()) return;
      login = null;
      loginCode = "";
      done(code === 0 ? { ok: true } : { error: (out.trim().split(/\r?\n/).pop() || "Chưa đăng nhập được ChatGPT.").slice(0, 300) });
    });
  };

  // The page and its two files, the same from the menu and from every tool's server.
  const PAGE = { "/setup": [join(here, "page.html"), "text/html"], "/setup/page.js": [join(here, "page.js"), "text/javascript"], "/setup/tool.css": [join(here, "..", "assets", "tool.css"), "text/css"] };
  return async function handle(req, res, path) {
    if (PAGE[path] && req.method === "GET") {
      res.writeHead(200, { "content-type": `${PAGE[path][1]}; charset=utf-8`, "cache-control": "no-store" });
      res.end(readFileSync(PAGE[path][0]));
      return true;
    }
    if (path === "/api/setup" && req.method === "POST") {
      const {status, report} = await readSetup();
      json(res, status, report);
      return true;
    }
    if (path === "/api/setup-login") {
      json(res, 200, { code: loginCode });
      return true;
    }
    if (path === "/api/setup-step" && req.method === "POST") {
      // Cài (Codex via npm, then the bridge) or Đăng nhập (opens the browser, waits for the sign-in).
      const { step, site } = await body(req);
      // Each AI's own sign-in page in Chrome, to sign in or switch accounts there.
      const SITES = { gemini: "https://gemini.google.com/app", flow: "https://flow.google.com/", chatgpt: "https://chatgpt.com/" };
      if (step === "google" || (step === "site" && SITES[site])) {
        const url = step === "google" ? "https://accounts.google.com/AccountChooser?continue=https%3A%2F%2Fgemini.google.com%2Fapp" : site === "chatgpt" ? SITES[site] : withAccount(SITES[site]);
        openInChrome(url, (r) => json(res, r.error ? 500 : 200, r));
        return true;
      }
      if (step === "antigravity") {
        // Antigravity signs in on its own (not through Chrome), from inside agy.
        const agy = findTool("agy") || [join(homedir(), ".local", "bin", onWindows ? "agy.exe" : "agy")].find((p) => existsSync(p));
        if (!agy) { json(res, 400, { error: "Chưa cài Antigravity CLI (agy)." }); return true; }
        openTerminal(agy);
        json(res, 200, { ok: true });
        return true;
      }
      if (step === "browser") {
        // Installing the extension: Chrome's extensions page, and the folder to choose there (Tải tiện ích đã giải nén).
        const folder = join(hubRoot, "core", "extension");
        if (onWindows) execFile("explorer.exe", [folder], () => {}); else execFile("open", [folder], () => {});
        // Not through the extension: this is where it gets installed.
        openChrome("chrome://extensions").then((error) => json(res, error ? 500 : 200, error ? { error } : { ok: true }));
        return true;
      }
      const npm = findTool("npm"), codex = findTool("codex");
      if (step === "login") {
        if (!codex) { json(res, 400, { error: "Chưa cài Codex." }); return true; }
        let answered = false;
        codexLogin(codex, (r) => { if (!answered) { answered = true; json(res, r.error ? 500 : 200, r); } });
        return true;
      }
      // Anything else (a site not listed, an unknown step) is refused; only Cài is left below.
      if (step !== "install") { json(res, 400, { error: "Bước không hỗ trợ." }); return true; }
      if (!npm) { json(res, 400, { error: "Chưa có Node.js. Mở lại start-app để cài." }); return true; }
      const [cmd, args] = [npm, ["install", "-g", "@openai/codex"]];
      runTool(cmd, args, { cwd: hubRoot, timeout: 15 * 60000, env, windowsHide: true }, (err, stdout, stderr) => {
        if (err) return json(res, 500, { error: (String(stderr || stdout).trim().split(/\r?\n/).pop() || err.message).slice(0, 300) });
        // The shared bridge between the tools and the Product Review extension (core/bridge).
        runTool(npm, ["install", "--silent"], { cwd: join(hubRoot, "core", "bridge"), timeout: 10 * 60000, env, windowsHide: true }, () => json(res, 200, { ok: true }));
      });
      return true;
    }
    if (path === "/api/usage" && req.method === "GET") {
      json(res, 200, { rows: summarizeUsage(readUsage(join(hubRoot, "workspace", "logs", "ai-usage.jsonl"))) });
      return true;
    }
    if (path === "/api/config/ai") {
      const saved = req.method === "POST" ? await body(req) : null;
      const script = saved
        ? `${load("ai-settings.ps1")}; Set-AiSettings '${q(hubRoot)}' $env:HUB_AI_MODEL $env:HUB_AI_EFFORT; '{"ok":true}'`
        : `${load("ai-settings.ps1")}; [pscustomobject]@{ settings = (Get-AiSettings '${q(hubRoot)}'); models = @(Get-AiModels) } | ConvertTo-Json -Depth 6 -Compress`;
      const r = await ps(script, saved ? { HUB_AI_MODEL: String(saved.model || ""), HUB_AI_EFFORT: String(saved.effort || "") } : {});
      json(res, r.error ? 400 : 200, r);
      return true;
    }
    if (path === "/api/config/google") {
      if (req.method === "POST") {
        const email = String((await body(req)).email || "").trim();
        if (email && !/^[^\s@"]+@[^\s@"]+$/.test(email)) { json(res, 400, { error: "Email không hợp lệ." }); return true; }
        if (email) { mkdirSync(dirname(googleFile), { recursive: true }); writeFileSync(googleFile, JSON.stringify({ email })); }
        else rmSync(googleFile, { force: true });
      }
      json(res, 200, { email: googleAccount() });
      return true;
    }
    return false;
  };
}
