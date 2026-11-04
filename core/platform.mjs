// What the Node server (src/mac/server.mjs) does differently on macOS and Windows: the
// same pages and servers run on both; on Windows the window is core/launch.ps1's WebView2 app window.
import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { homedir } from "node:os";
import { appProfile, executable as toolsChrome } from "./browser.mjs";

export const onWindows = process.platform === "win32";

// Node, npm and codex: Homebrew or the npm prefix on macOS (Finder-launched apps miss them in PATH), the Node
// installer's folder and %APPDATA%\npm on Windows.
const extraPath = onWindows
  ? [join(process.env.ProgramFiles || "C:\\Program Files", "nodejs"), join(process.env.APPDATA || join(homedir(), "AppData", "Roaming"), "npm")]
  : ["/opt/homebrew/bin", "/usr/local/bin", join(homedir(), ".npm-global", "bin"), join(homedir(), ".dotnet", "tools")];
export const toolEnv = { ...process.env, PATH: [...new Set([...(process.env.PATH || "").split(delimiter), ...extraPath, dirname(process.execPath)])].filter(Boolean).join(delimiter) };
export const findTool = (name, env = toolEnv) => String(env.PATH || env.Path || "").split(delimiter).filter(Boolean)
  .flatMap((d) => (onWindows ? [".cmd", ".exe", ""] : [""]).map((ext) => join(d, name + ext))).find((p) => existsSync(p));
// npm and codex are .cmd files on Windows, which Node only starts through the shell.
export function runTool(cmd, args, options, done) {
  if (onWindows && /\.cmd$/i.test(cmd)) return execFile(`"${cmd}"`, args, { ...options, shell: true }, done);
  return execFile(cmd, args, options, done);
}

// Windows PowerShell 5.1 is on every Windows; pwsh 7 on macOS.
export const PWSH = process.env.PR_PWSH || (onWindows ? "powershell.exe"
  : [...(process.env.PATH || "").split(delimiter).map((d) => join(d, "pwsh")), "/opt/homebrew/bin/pwsh", "/usr/local/bin/pwsh",
    join(homedir(), ".dotnet", "tools", "pwsh"), "/usr/local/microsoft/powershell/7/pwsh"].find((p) => existsSync(p)) || "pwsh");
// Arguments for a PowerShell command, and for a script with its parameters ("-Name", value, …). On Windows both run
// past the execution policy and talk UTF-8 on stdin/stdout (5.1 uses the console code page otherwise).
const utf8 = "[Console]::InputEncoding=[Console]::OutputEncoding=New-Object Text.UTF8Encoding $false; ";
const quote = (s) => `'${String(s).replace(/'/g, "''")}'`;
export const psCommand = (command) => (onWindows ? ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", utf8 + command] : ["-NoProfile", "-Command", command]);
export const psFile = (file, args = []) => (onWindows
  ? psCommand(`& ${quote(file)} ${args.map((a) => (/^-[A-Za-z]+$/.test(a) ? a : quote(a))).join(" ")}; exit $LASTEXITCODE`)
  : ["-NoProfile", "-File", file, ...args]);

// Stop every process whose command line has this text (a tool's server, the menu), as pkill -f does.
export function killMatching(text, done = () => {}) {
  if (!onWindows) return execFile("pkill", ["-f", text], () => done());
  execFile(PWSH, psCommand(`Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains(${quote(text)}) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`), { windowsHide: true }, () => done());
}
// Stop a process and everything it started (Dừng: run-images.ps1, codex and their children). On macOS the process
// was started detached, so it leads its own group.
export function killTree(proc) {
  if (onWindows) return execFile("taskkill", ["/PID", String(proc.pid), "/T", "/F"], { windowsHide: true }, () => {});
  try { process.kill(-proc.pid, "SIGKILL"); } catch { try { proc.kill("SIGKILL"); } catch {} }
}

// The user's own Chrome, where the Product Review extension (core/extension) is installed and the AIs are signed in: started,
// or a page opened in it. background: Chrome is not brought to the front (a run starting it).
export function openChrome(url = "", { background = false } = {}) {
  return new Promise((resolve) => {
    const done = (err) => resolve(err ? "Không mở được Google Chrome. Cài Google Chrome rồi thử lại." : "");
    if (onWindows) return execFile("cmd", ["/c", "start", "", "chrome", ...(url ? [url] : [])], { windowsHide: true }, done);
    execFile("open", [...(background ? ["-g"] : []), "-a", "Google Chrome", ...(url ? [url] : [])], done);
  });
}

// A window of its own on macOS: Chrome for Testing (core/browser.mjs) in app mode (no tabs or address bar); before
// it is downloaded, the user's Chrome, else the default browser. On Windows the app window (core/launch.ps1) shows the
// pages, so nothing opens here.
export function appWindow(url, size = "1120,840") {
  if (onWindows) return;
  const args = [`--app=${url}`, `--window-size=${size}`];
  if (existsSync(toolsChrome)) {
    return spawn(toolsChrome, [`--user-data-dir=${appProfile}`, "--no-first-run", "--no-default-browser-check", "--disable-infobars", ...args], { detached: true, stdio: "ignore" }).unref();
  }
  execFile("open", ["-na", "Google Chrome", "--args", ...args], (err) => { if (err) execFile("open", [url]); });
}

// A terminal window running a program the user works in themselves (Antigravity's /login): Terminal on macOS, a
// console window on Windows.
export function openTerminal(program) {
  if (onWindows) return spawn("cmd.exe", ["/c", "start", '""', "cmd.exe", "/k", `"${program}"`], { detached: true, stdio: "ignore", windowsHide: false, windowsVerbatimArguments: true }).unref();
  const quoted = `'${program.replace(/'/g, "'\\''")}'`;
  execFile("osascript", ["-e", `tell application "Terminal" to do script "${quoted.replace(/["\\]/g, "\\$&")}"`, "-e", 'tell application "Terminal" to activate']);
}

// The system file dialog: real paths, opened at folder. filter is "images" or "table" (CSV or ZIP / RAR / 7Z).
export function chooseFiles({ folder = "", table = false }, done) {
  const lines = (err, stdout) => done(err ? [] : String(stdout).split(/\r?\n/).map((p) => p.trim()).filter(Boolean));
  if (onWindows) {
    const filter = table ? "Bảng nhập|*.csv;*.zip;*.rar;*.7z" : "Ảnh|*.png;*.jpg;*.jpeg";
    const script = `Add-Type -AssemblyName System.Windows.Forms; $d=New-Object Windows.Forms.OpenFileDialog; $d.Multiselect=$true; $d.Title=${quote(table ? "Chọn bảng nhập" : "Chọn ảnh")}; $d.Filter=${quote(filter)}; `
      + `if(${quote(folder)} -and (Test-Path -LiteralPath ${quote(folder)})){$d.InitialDirectory=${quote(folder)}}; `
      + `$owner=New-Object Windows.Forms.Form -Property @{TopMost=$true;ShowInTaskbar=$false;Opacity=0}; $owner.Show(); `
      + `if($d.ShowDialog($owner) -eq 'OK'){$d.FileNames}; $owner.Dispose()`;
    return execFile(PWSH, ["-STA", ...psCommand(script)], { windowsHide: true }, lines);
  }
  const at = folder && existsSync(folder) ? ` default location (POSIX file ${JSON.stringify(folder)})` : "";
  const what = table ? `"Chọn bảng nhập" of type {"csv", "zip", "rar", "7z"}` : `"Chọn ảnh" of type {"public.png", "public.jpeg"}`;
  const script = `set picked to choose file with prompt ${what} with multiple selections allowed${at}
set out to ""
repeat with f in picked
set out to out & POSIX path of f & linefeed
end repeat
return out`;
  execFile("osascript", ["-e", script], lines);
}
