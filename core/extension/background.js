// Router: keeps a WebSocket to the local bridge (core/bridge) and forwards each job to the matching tab.
// The job is submitted inside the signed-in tab, so the page itself handles its own anti-abuse checks.
// It runs in the user's own Chrome: jobs only use tabs it opened itself, in the Chrome window already open, in a tab
// group named Product Video; the user's own tabs are never touched. Jobs run side by side (the bridge sends at most as many
// as a tool runs threads), each in a tab of its own, opened in the background and closed once the job is done; a run
// starts by closing the group's tabs (session). A site only works in a tab that is shown (Gemini stops answering behind
// another tab): while a job works, the debugger keeps its tab rendering as if shown (keepShown), and Chrome shows its
// "debugging" bar. A site's files are sites/<site>.js; a new AI is one more entry in SITES.
const BRIDGE_URL = "ws://127.0.0.1:8785";
// hosts: the tabs to look through; page: a tab a job can run in (a Flow project, under /u/<n>/ for another account).
const SITES = {
  chatgpt: { hosts: "https://chatgpt.com/*", page: /^https:\/\/chatgpt\.com\//, start: "https://chatgpt.com/", fresh: true },
  flow: { hosts: "https://flow.google.com/*", page: /^https:\/\/flow\.google\.com\/(u\/\d+\/)?project\//, start: "https://flow.google.com/" },
  gemini: { hosts: "https://gemini.google.com/*", page: /^https:\/\/gemini\.google\.com\//, start: "https://gemini.google.com/app", fresh: true },
  // Grok Imagine: images and videos (job.kind), with whoever is signed in to grok.com.
  grok: { hosts: "https://grok.com/*", page: /^https:\/\/grok\.com\//, start: "https://grok.com/imagine", fresh: true },
};
// Flow and Gemini run with the Google account chosen on Cấu hình (job.account; "" is Google's default, the first one
// signed in), opened with ?authuser=; Google then shows the page under /u/<n>/.
const startUrl = (platform, account) => SITES[platform].start + (account ? `?authuser=${encodeURIComponent(account)}` : "");
// Each job's tab opens on the site's start page, a new chat, so earlier images and answers are never reused.
// The job each tab works for, so its page's steps are logged under that job.
const tabJobs = new Map();
const GROUP = "Product Video";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Chrome refuses tab changes while the user drags a tab ("Tabs cannot be edited right now"): try again shortly.
async function tabsCall(call) {
  for (let i = 0; ; i++) {
    try { return await call(); } catch (error) {
      if (i >= 20 || !/cannot be edited|dragging/i.test(String(error.message || error))) throw error;
      await sleep(300);
    }
  }
}
const answer = (id, work) => work.then((r) => reply({ type: "result", id, ok: true, ...r }), (e) => reply({ type: "result", id, ok: false, error: String(e.message || e) }));

let socket = null;

function connect() {
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  socket = new WebSocket(BRIDGE_URL);
  socket.onopen = () => {
    socket.send(JSON.stringify({ type: "hello", version: chrome.runtime.getManifest().version }));
    chrome.storage.session.set({ connected: true });
  };
  socket.onclose = () => { socket = null; chrome.storage.session.set({ connected: false }); };
  socket.onerror = () => {};
  socket.onmessage = (event) => {
    let job;
    try { job = JSON.parse(event.data); } catch { return; }
    // A job of a connection that has since closed (the bridge restarted) is dropped: nobody waits for its answer.
    const from = socket;
    if (job.type === "generate" && from === socket) runJob(job);
    if (job.type === "session") answer(job.id, newSession());
    if (job.type === "open") answer(job.id, openPage(job.url).then(() => ({})));
    if (job.type === "logins") answer(job.id, logins());
    // After an update the app asks for this, so the new files load without a click in chrome://extensions.
    if (job.type === "reload") chrome.runtime.reload();
  };
}

function reply(message) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

// A tab of the job's own: a new chat, or for Flow a project no other job is using now.
async function jobTab(platform, account) {
  if (!SITES[platform]) throw new Error(`Nền tảng không hỗ trợ: ${platform}`);
  if (platform === "flow") return flowProject(account);
  const tab = await toolsTab(startUrl(platform, account));
  await waitForLoad(tab.id);
  return tab;
}

// A run starts with only its own tabs: the Product Video group's tabs, in every window, are closed (Cấu hình's sign-in
// pages too); the user's other tabs stay. The bridge asks only while no job is waiting.
async function newSession() {
  const groups = await chrome.tabGroups.query({ title: GROUP });
  const tabs = (await Promise.all(groups.map((g) => chrome.tabs.query({ groupId: g.id })))).flat().map((t) => t.id);
  if (tabs.length) await tabsCall(() => chrome.tabs.remove(tabs));
  await chrome.storage.session.remove(["tabs", "flowHome"]);
  flowBusy.clear();
  return { closed: tabs.length };
}

// A tab of the tools: in the Chrome window open now (a new window only when there is none), not brought to the front,
// in that window's Product Video group.
async function toolsTab(url) {
  const window = await chrome.windows.getLastFocused({ windowTypes: ["normal"] }).catch(() => null);
  const tab = window ? await tabsCall(() => chrome.tabs.create({ url, windowId: window.id, active: false })) : (await chrome.windows.create({ url })).tabs[0];
  await group(tab);
  return tab;
}
// A page a tool opens for the user (Cấu hình: sign-in, Flow, Gemini): in front, in the Product Video group, with Chrome's
// window brought forward.
async function openPage(url) {
  const tab = await toolsTab(url);
  await tabsCall(() => chrome.tabs.update(tab.id, { active: true }));
  await chrome.windows.update(tab.windowId, { focused: true });
}
async function group(tab) {
  try {
    const [existing] = await chrome.tabGroups.query({ windowId: tab.windowId, title: GROUP });
    const groupId = tab.groupId > -1 ? tab.groupId : await tabsCall(() => chrome.tabs.group({ tabIds: tab.id, ...(existing ? { groupId: existing.id } : { createProperties: { windowId: tab.windowId } }) }));
    await tabsCall(() => chrome.tabGroups.update(groupId, { title: GROUP, color: "blue", collapsed: false }));
  } catch {}
}

// Flow keeps its projects per account for every run (their addresses in chrome.storage.local), so runs leave no new
// projects behind: one per job running at once, since a job finds its images as the newest in its project's grid. A job
// takes the first project no other job is using (slot); one that no longer opens (deleted in Flow) is replaced.
const flowBusy = new Map();
async function flowProject(account) {
  const busy = flowBusy.get(account) || new Set();
  flowBusy.set(account, busy);
  let slot = 0;
  while (busy.has(slot)) slot++;
  busy.add(slot);
  try {
    const { flowProjects = {} } = await chrome.storage.local.get("flowProjects");
    const saved = [].concat(flowProjects[account] || [])[slot];
    if (saved) {
      reply({ type: "progress", id: "tab", stage: `opening Flow project ${slot + 1}` });
      const tab = await toolsTab(saved);
      await waitForLoad(tab.id);
      await sleep(1500);
      const now = await chrome.tabs.get(tab.id);
      if (SITES.flow.page.test(now.url || "") && now.url.split("?")[0] === saved) return Object.assign(now, { slot });
      await tabsCall(() => chrome.tabs.remove(tab.id)).catch(() => {});
    }
    const tab = await newFlowProject(account);
    const { flowProjects: latest = {} } = await chrome.storage.local.get("flowProjects");
    const list = [].concat(latest[account] || []);
    list[slot] = tab.url.split("?")[0];
    latest[account] = list;
    await chrome.storage.local.set({ flowProjects: latest });
    return Object.assign(tab, { slot });
  } catch (error) {
    busy.delete(slot);
    throw error;
  }
}

// No Flow project for this slot: open Flow's home (as the chosen account) and press its new-project button; that tab
// then is the project.
async function newFlowProject(account) {
  const tab = await toolsTab(startUrl("flow", account));
  try {
    await waitForLoad(tab.id);
    const ask = () => chrome.tabs.sendMessage(tab.id, { type: "new-project" });
    const at = await ask().catch(async () => { await chrome.tabs.reload(tab.id); await waitForLoad(tab.id); return ask(); }).catch(() => null);
    if (!at?.ok) throw new Error(at?.error || "Không mở được Google Flow. Đăng nhập Google trong Chrome rồi chạy lại.");
    reply({ type: "progress", id: "tab", stage: "clicking Flow's new-project button" });
    const stop = await keepShown(tab);
    try { await trustedClick(tab, at.x, at.y); } finally { await stop(); }
    for (let i = 0; i < 60; i++) {
      const now = await chrome.tabs.get(tab.id);
      if (SITES.flow.page.test(now.url || "") && now.status === "complete") return now;
      await sleep(500);
    }
    throw new Error("Google Flow chưa tạo được dự án mới.");
  } catch (error) {
    await tabsCall(() => chrome.tabs.remove(tab.id)).catch(() => {});
    throw error;
  }
}

// A page that finished loading before the listener was added (a fast or cached one) sends no more "complete": the tab's
// status is checked too, and after 60 s the job goes on anyway (sendJob asks the page until its script answers).
function waitForLoad(tabId) {
  return new Promise((resolve) => {
    const done = () => { chrome.tabs.onUpdated.removeListener(listener); clearTimeout(timer); resolve(); };
    const listener = (id, info) => { if (id === tabId && info.status === "complete") done(); };
    const timer = setTimeout(done, 60000);
    chrome.tabs.onUpdated.addListener(listener);
    chrome.tabs.get(tabId).then((tab) => { if (tab.status === "complete") done(); }, done);
  });
}

// Google's "unusual traffic" page (google.com/sorry) in place of the site: only the user gets past it (a check of
// their own), and jobs sent meanwhile would only add to it.
const GOOGLE_SORRY = "Google tạm giới hạn tài khoản/máy này vì lưu lượng bất thường (trang google.com/sorry). Mở Cấu hình, bấm Mở Gemini, tự xác minh trong Chrome rồi chạy lại.";

async function runJob(job) {
  const progress = (stage) => reply({ type: "progress", id: job.id, stage });
  let tab = null, stop = null;
  const account = ["chatgpt", "grok"].includes(job.platform) ? "" : String(job.account || "");
  try {
    tab = await jobTab(job.platform, account);
    tabJobs.set(tab.id, job.id);
    if (/^https:\/\/www\.google\.com\/sorry\//.test((await chrome.tabs.get(tab.id)).url || "")) throw new Error(GOOGLE_SORRY);
    stop = await keepShown(tab);
    // Grok folds its composer's settings (length, resolution, aspect) away in a narrow window: its tab is laid out at a
    // desktop size whatever the size of the user's Chrome window.
    if (job.platform === "grok") await chrome.debugger.sendCommand({ tabId: tab.id }, "Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false }).catch(() => {});
    progress("submitting");
    let result = await sendJob(tab, job);
    if (!result || !result.ok) throw new Error(result?.error || "Tab không trả kết quả.");
    if (result.url && !result.data) {
      // Signed Flow links are fetched here, where the host permission applies.
      const response = await fetch(result.url, { credentials: "include" });
      if (!response.ok) throw new Error(`Tải ảnh Flow lỗi ${response.status}`);
      const blob = await response.blob();
      result = { mime: blob.type, data: await toBase64(blob), source: result.source };
    }
    reply({ type: "result", id: job.id, ok: true, ...result });
  } catch (error) {
    reply({ type: "result", id: job.id, ok: false, error: String(error.message || error) });
  } finally {
    if (stop) await stop();
    if (tab) {
      tabJobs.delete(tab.id);
      await tabsCall(() => chrome.tabs.remove(tab.id)).catch(() => {});
      if (tab.slot !== undefined) flowBusy.get(account)?.delete(tab.slot);
    }
  }
}

// The job to the tab's page script. A tab just opened can be loaded before its script is (several opening at once): it
// is asked again until the script is there, the page reloaded once on the way. Only a page with no script fails to
// take it, so the job is never sent twice.
async function sendJob(tab, job) {
  for (let i = 1; ; i++) {
    try { return await chrome.tabs.sendMessage(tab.id, { type: "generate", job }); } catch (error) {
      if (!/Receiving end does not exist|Could not establish connection/i.test(String(error.message || error))) throw error;
      if (i >= 30) throw new Error(`Trang ${(await chrome.tabs.get(tab.id).catch(() => ({}))).url || "?"} không nhận việc (script của extension không chạy trong tab).`);
      if (i === 10) { await chrome.tabs.reload(tab.id); await waitForLoad(tab.id); } else await sleep(1000);
    }
  }
}

async function toBase64(blob) {
  const buffer = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  for (let i = 0; i < buffer.length; i += 0x8000) binary += String.fromCharCode(...buffer.subarray(i, i + 0x8000));
  return btoa(binary);
}

// Who is signed in, for Cấu hình: Google (its sign-in cookie covers Flow and Gemini; accounts: every one signed in,
// the first being Google's default) and ChatGPT (next-auth's session cookie, sometimes split).
async function logins() {
  const has = async (domain, test) => (await chrome.cookies.getAll({ domain })).some((c) => test(c.name));
  const google = await has("google.com", (n) => n === "SID" || n === "__Secure-1PSID");
  let accounts = [];
  if (google) {
    try {
      // Google answers its account list only to its own pages: this one request says it comes from www.google.com.
      await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [1], addRules: [{ id: 1, priority: 1,
        action: { type: "modifyHeaders", requestHeaders: [{ header: "origin", operation: "set", value: "https://www.google.com" }] },
        condition: { urlFilter: "|https://accounts.google.com/ListAccounts", resourceTypes: ["xmlhttprequest", "other"], initiatorDomains: [chrome.runtime.id] } }] });
      const r = await fetch("https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard", { method: "POST", credentials: "include" });
      accounts = JSON.parse(await r.text())[1].map((a) => a[3]).filter((e) => /@/.test(e));
    } catch {}
  }
  return { google, accounts, chatgpt: await has("chatgpt.com", (n) => n.startsWith("__Secure-next-auth.session-token")) };
}

// MV3 workers sleep; an alarm wakes the worker to reconnect to the bridge.
chrome.alarms.create("bridge", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
// The tabs the debugger keeps shown now (keepShown), each with how to attach again; a click goes through the same session.
const shown = new Map();
// Keeps a background tab working as if shown, until the returned stop(): a screencast of it makes Chrome render it as a
// visible page (timers run at full speed, answers keep coming), and focus emulation makes it act as the focused page.
// The frames are tiny, rare and dropped. On battery Chrome may still freeze a background page, so it is woken every
// 15 s; and when the debugger is taken off mid-job (the "debugging" bar cancelled), it is attached again.
async function keepShown(tab) {
  const target = { tabId: tab.id };
  const start = async () => {
    await chrome.debugger.attach(target, "1.3");
    await chrome.debugger.sendCommand(target, "Page.enable");
    await chrome.debugger.sendCommand(target, "Emulation.setFocusEmulationEnabled", { enabled: true });
    await chrome.debugger.sendCommand(target, "Page.startScreencast", { format: "jpeg", quality: 1, maxWidth: 32, maxHeight: 32, everyNthFrame: 60 });
  };
  try { await start(); } catch (error) {
    await chrome.debugger.detach(target).catch(() => {});
    throw error;
  }
  shown.set(tab.id, start);
  const wake = setInterval(() => chrome.debugger.sendCommand(target, "Page.setWebLifecycleState", { state: "active" }).catch(() => {}), 15000);
  return async () => {
    clearInterval(wake);
    if (!shown.delete(tab.id)) return;
    await chrome.debugger.detach(target).catch(() => {});
  };
}
chrome.debugger.onEvent.addListener((source, method, params) => {
  if (method === "Page.screencastFrame") chrome.debugger.sendCommand(source, "Page.screencastFrameAck", { sessionId: params.sessionId }).catch(() => {});
});
chrome.debugger.onDetach.addListener((source, reason) => {
  const start = shown.get(source.tabId);
  if (!start) return;
  reply({ type: "progress", id: tabJobs.get(source.tabId) || "tab", stage: `debugger detached (${reason}), attaching again` });
  start().catch((error) => reply({ type: "progress", id: tabJobs.get(source.tabId) || "tab", stage: `debugger not attached again: ${error.message || error}` }));
});

// A real left click at (x, y) in the tab's viewport, sent through the debugger so the page sees a trusted event. The tab
// stays where it is, in the background.
async function trustedClick(tab, x, y) {
  const target = { tabId: tab.id };
  const own = !shown.has(tab.id);
  if (own) await chrome.debugger.attach(target, "1.3");
  try {
    const mouse = (type, extra = {}) => chrome.debugger.sendCommand(target, "Input.dispatchMouseEvent", { type, x, y, button: "left", ...extra });
    await mouse("mouseMoved", { button: "none" });
    await mouse("mousePressed", { buttons: 1, clickCount: 1 });
    await mouse("mouseReleased", { buttons: 0, clickCount: 1 });
  } finally {
    if (own) await chrome.debugger.detach(target).catch(() => {});
  }
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "click" && _sender.tab) {
    trustedClick(_sender.tab, message.x, message.y).then(() => sendResponse({ ok: true }), (error) => sendResponse({ ok: false, error: String(error.message || error) }));
    return true;
  }
  if (message?.type === "progress" && _sender.tab) {
    reply({ type: "progress", id: tabJobs.get(_sender.tab.id) || "tab", stage: message.stage });
    return;
  }
  if (message?.type === "needs-click" && _sender.tab) {
    // The automatic click did not start Flow: bring that tab to the front for the user's click.
    chrome.tabs.update(_sender.tab.id, { active: true });
    chrome.windows.update(_sender.tab.windowId, { focused: true });
    reply({ type: "progress", id: "flow", stage: "waiting for the Flow click" });
    return;
  }
});
connect();
