// Lượt dùng AI on Cấu hình: every AI call, from workspace/logs/ai-usage.jsonl (core/ai/ai.ps1 writes the CLIs,
// core/bridge/server.mjs the web AIs), added up per AI and account for today, 7 and 30 days. A line:
//   { t, ai, kind, account, ok, cause?, ms, in?, cached?, out? }   (in/cached/out: Codex tokens)
// The web AIs say nothing of their quota, so the last failure is shown, and whether a call has worked since: a
// QUOTA with nothing working after it is most likely that account's limit for now.
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";

// The AIs of core/ai/ai.ps1 ($script:HubAIProviders), in its order.
export const AI_NAMES = { codex: "Codex CLI", gemini: "Gemini web", flow: "Google Flow", chatgpt: "ChatGPT web", antigravity: "Antigravity CLI" };
const DAY = 86400000;

// The file stays small: over maxBytes, only the last keepDays days are kept.
export function readUsage(file, { now = new Date(), maxBytes = 4 << 20, keepDays = 90 } = {}) {
  if (!existsSync(file)) return [];
  const entries = [];
  for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const e = JSON.parse(line);
      if (e && e.ai && !Number.isNaN(Date.parse(e.t))) entries.push(e);
    } catch {}
  }
  if (statSync(file).size > maxBytes) {
    const kept = entries.filter((e) => now - Date.parse(e.t) < keepDays * DAY);
    try { writeFileSync(file, kept.map((e) => JSON.stringify(e)).join("\n") + (kept.length ? "\n" : "")); } catch {}
    return kept;
  }
  return entries;
}

const empty = () => ({ calls: 0, fail: 0, tokens: 0 });

export function summarizeUsage(entries, { now = new Date() } = {}) {
  const midnight = new Date(now); midnight.setHours(0, 0, 0, 0);
  const windows = { today: midnight.getTime(), week: now - 7 * DAY, month: now - 30 * DAY };
  const rows = new Map();
  for (const e of [...entries].sort((a, b) => Date.parse(a.t) - Date.parse(b.t))) {
    const at = Date.parse(e.t);
    if (at < windows.month) continue;
    const key = `${e.ai}\n${e.account || ""}`;
    if (!rows.has(key)) rows.set(key, { ai: e.ai, name: AI_NAMES[e.ai] || e.ai, account: e.account || "", today: empty(), week: empty(), month: empty(), last: "", lastFail: null, okSinceFail: false });
    const row = rows.get(key);
    for (const [name, from] of Object.entries(windows)) {
      if (at < from) continue;
      row[name].calls++;
      if (!e.ok) row[name].fail++;
      row[name].tokens += (Number(e.in) || 0) + (Number(e.out) || 0);
    }
    row.last = e.t;
    if (e.ok) row.okSinceFail = true;
    else { row.lastFail = { t: e.t, cause: e.cause || "UNKNOWN" }; row.okSinceFail = false; }
  }
  const order = Object.keys(AI_NAMES);
  return [...rows.values()].sort((a, b) => (order.indexOf(a.ai) + 1 || 99) - (order.indexOf(b.ai) + 1 || 99) || a.account.localeCompare(b.account));
}
