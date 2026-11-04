// Google Flow: paste references and the prompt into the composer, press the generate button, then return the new
// image. Flow only starts a generation from a real click: the background clicks it through the debugger (a trusted
// mouse event). When that does not start one, the button is highlighted for the user to press once.
// Flow's own images: flow.google.com/asb/<id> now, flow-content.google/image/<id> before.
const isFlowImage = (img) => /^https:\/\/(flow\.google\.com\/asb\/|flow-content\.google\/image\/)/.test(img.src);
const flowImages = () => new Set([...document.images].filter(isFlowImage).map((img) => img.src.split("?")[0]));
// Each item of the project grid is named: an uploaded file by its file name (ref-1.jpg, from the bridge), an image Flow
// made by a title of its own. That tells a reference that finished uploading late from a result.
// A run keeps using one project per account (the background), so the grid also holds the items of earlier jobs, under
// the same names: a reference of this job is an item of its name that was not there before, or whose image is new.
const tiles = () => [...document.querySelectorAll("flow-grid-tile-container")];
const tileName = (el) => el.closest("flow-grid-tile-container")?.getAttribute("aria-label") || "";
const named = (name) => tiles().filter((t) => t.getAttribute("aria-label") === name);
const freshImage = (tile, before) => [...tile.querySelectorAll("img")].some((img) => isFlowImage(img) && !before.has(img.src.split("?")[0]) && img.complete && img.naturalWidth > 0);

// A generation Flow refuses shows a card (Không thành công: "Lượt tạo này có thể vi phạm các chính sách…", not charged)
// in place of an image, and is gone after a reload: its title is the sign, its text the reason the run reports.
const failCards = () => [...document.querySelectorAll("body *")].filter((e) => e.children.length === 0 && /^(Không thành công|Failed|Generation failed|Unsuccessful)$/i.test(e.textContent.trim()) && e.getBoundingClientRect().width > 0);
const failReason = (card) => (card.parentElement?.innerText || card.textContent).replace(/\s+/g, " ").trim();

// Flow makes the image at the aspect set in its composer (16:9 unless changed), so a review photo of another shape
// is recomposed to fit: camera angle, room and furniture all change. Before the references go in, the aspect closest
// to the first image (the review photo) is chosen. Failing to set it does not stop the run.
const FLOW_ASPECTS = [["16:9", 16 / 9], ["4:3", 4 / 3], ["1:1", 1], ["3:4", 3 / 4], ["9:16", 9 / 16]];
const FLOW_ICONS = { "16:9": "16_9", "4:3": "landscape", "1:1": "square", "3:4": "portrait", "9:16": "9_16" };
const settingsButton = () => document.querySelector("button.settings-trigger-button");
const aspectToggle = (label) => [...document.querySelectorAll(".cdk-overlay-container button.mat-button-toggle-button")].find((b) => b.innerText.split(/\s+/).includes(label));
const realClick = (el) => {
  const box = el.getBoundingClientRect();
  return chrome.runtime.sendMessage({ type: "click", x: box.left + box.width / 2, y: box.top + box.height / 2 }).catch(() => null);
};
async function setFlowAspect(file) {
  try {
    const bitmap = await createImageBitmap(file);
    const ratio = bitmap.width / bitmap.height;
    bitmap.close();
    const [label] = FLOW_ASPECTS.reduce((best, a) => (Math.abs(Math.log(a[1] / ratio)) < Math.abs(Math.log(best[1] / ratio)) ? a : best));
    const trigger = await waitFor(settingsButton, 10000, "nút cài đặt của Flow");
    await realClick(trigger);
    const toggle = await waitFor(() => aspectToggle(label), 5000, "tỷ lệ khung hình của Flow");
    // The settings button shows the chosen aspect as its icon (crop_16_9, crop_square, ...), the sign that it took.
    const chosen = () => settingsButton()?.innerText.includes(`crop_${FLOW_ICONS[label]}`);
    if (!chosen()) {
      await realClick(toggle);
      await waitFor(chosen, 5000, "chọn tỷ lệ khung hình");
    }
    note(`aspect ${label} for a ${(ratio).toFixed(2)} review photo`);
    await realClick(trigger);
    await sleep(400);
  } catch (error) {
    note(`aspect not set: ${error.message || error}`);
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  }
}

async function generateFlow(job) {
  const composer = () => document.querySelector('.ProseMirror[contenteditable="true"]');
  let editor = await waitFor(composer, 30000, "ô nhập Flow");
  note(`composer found, visible: ${document.visibilityState}`);
  if (flowAgentOn()) {
    note("turning Tác nhân off");
    await turnAgentOff();
    editor = await waitFor(composer, 30000, "ô nhập Flow");
  }
  if (job.images?.length) {
    await setFlowAspect(filesFromJob({ images: job.images.slice(0, 1) })[0]);
    editor = await waitFor(composer, 30000, "ô nhập Flow");
  }
  // The grid shows only the items in view, newest first: from the top, the new items of this job are the first ones.
  document.querySelector(".cdk-virtual-scrollable")?.scrollTo({ top: 0 });
  await sleep(500);
  const before = flowImages();
  const files = filesFromJob(job);
  const names = new Set(files.map((f) => f.name));
  const counts = Object.fromEntries(files.map((f) => [f.name, named(f.name).length]));
  consentClicks = 0;
  // Each reference shows up in the project grid under its file name: uploading, then done. A project sometimes drops
  // a paste (no item ever comes): only the files with no item yet are pasted again, so none is sent twice.
  const done = (name) => named(name).some((t) => freshImage(t, before));
  const arrived = (name) => named(name).length > counts[name] || done(name);
  let missing = files;
  for (let paste = 1; paste <= 3 && missing.length; paste++) {
    await pasteFiles(editor, missing);
    note(`pasted ${missing.map((f) => f.name).join(", ")}, try ${paste}`);
    const uploaded = () => {
      if (agreeToConsent()) return false;
      return files.every((f) => done(f.name));
    };
    try { await waitFor(uploaded, 45000, "tải ảnh tham khảo lên Flow"); missing = []; }
    catch (error) {
      if (error.message === FLOW_CONSENT) throw error;
      // Still uploading (its item is there): wait for it longer instead of sending it again.
      missing = files.filter((f) => !arrived(f.name));
      if (!missing.length) { await waitFor(uploaded, 120000, "tải ảnh tham khảo lên Flow"); break; }
      if (paste === 3) throw error;
      editor = await waitFor(composer, 30000, "ô nhập Flow");
    }
  }
  if (files.length) {
    flowImages().forEach((src) => before.add(src));
    // Flow draws the composer again once a reference is attached.
    editor = await waitFor(composer, 30000, "ô nhập Flow");
  }
  typePrompt(editor, job.prompt);
  const failsBefore = failCards().length;
  const button = await waitFor(() => document.querySelector("button.generate-icon-button:not([disabled])"), 30000, "nút tạo của Flow");
  button.scrollIntoView({ block: "center" });
  await sleep(300);
  // Started once the composer lets go of the prompt or the button turns off.
  const started = () => !editor.innerText.includes(job.prompt.slice(0, 20)) || button.disabled || !button.isConnected;
  const box = button.getBoundingClientRect();
  const clicked = await chrome.runtime.sendMessage({ type: "click", x: box.left + box.width / 2, y: box.top + box.height / 2 }).catch(() => null);
  const going = clicked?.ok && (await waitFor(started, 15000, "").catch(() => false));
  note(going ? "generation started" : `generate click did not start it (${clicked?.error || "no answer"})`);
  if (!going) {
    button.style.outline = "3px solid #f5b400";
    button.style.outlineOffset = "3px";
    chrome.runtime.sendMessage({ type: "needs-click", platform: "flow" });
  }

  // Flow makes more than one image per generation (x2): once a refusal card comes, the other images get 20 s more.
  let refusedAt = 0;
  const src = await waitFor(() => {
    // Never one of the references (even one that finished uploading after the generation started), nor an item of an
    // earlier job that came into view later: only the first few tiles are this job's.
    const recent = new Set(tiles().slice(0, files.length + 4));
    const fresh = [...document.images].find((img) => isFlowImage(img) && recent.has(img.closest("flow-grid-tile-container")) && !before.has(img.src.split("?")[0]) && !names.has(tileName(img)) && img.complete && img.naturalWidth > 0);
    if (fresh) return fresh.src;
    const fails = failCards();
    if (fails.length > failsBefore) {
      if (!refusedAt) { refusedAt = Date.now(); note(`generation refused: ${failReason(fails[0])}`); }
      if (Date.now() - refusedAt > 20000) throw new Error(`Google Flow từ chối tạo ảnh: ${failReason(fails[0])}`);
    }
    return null;
  }, (job.timeoutSec || 600) * 1000, "Flow tạo ảnh (bấm Bắt đầu tạo trong tab Flow)");
  button.style.outline = "";
  return { url: src, source: location.href };
}

onJob(generateFlow);

// An account that has never used Flow first gets a welcome dialog (Tiếp theo / Đăng xuất) over the page; a click on
// Dự án mới then lands on it. Only the user goes through it (Cấu hình → Mở Flow).
const FLOW_WELCOME = "Google Flow của tài khoản đang chọn đang hiện màn hình chào lần đầu. Mở Cấu hình, bấm Mở Flow, bấm Tiếp theo cho xong rồi chạy lại.";
// Flow's agent mode (Tác nhân) answers in a chat and makes video, not the image the run waits for; some accounts start
// each project with it on. The run turns it off (a real click, like the generate button), and Flow's image model (Nano
// Banana) is then the one in the composer. Only when that does not work does the run stop and say so.
const FLOW_AGENT = "Google Flow của tài khoản đang chọn đang bật Tác nhân và app chưa tắt được, nên không tạo ảnh. Mở Cấu hình, bấm Mở Flow, vào một dự án, tắt Tác nhân và chọn mô hình ảnh Nano Banana rồi chạy lại.";
// Some accounts are asked, at every upload, to confirm they have the rights to the image (Quyền sử dụng hình ảnh này:
// Tôi đồng ý / Huỷ). The user chose to have the run agree for them (a real click, one dialog at a time); when the
// dialogs keep coming back the run stops and says so.
const FLOW_CONSENT = "Google Flow của tài khoản đang chọn cứ hỏi đồng ý quyền sử dụng hình ảnh và app bấm Tôi đồng ý không qua được. Mở Cấu hình, bấm Mở Flow, vào một dự án, tải một ảnh lên và bấm Tôi đồng ý rồi chạy lại.";
const consentAgreeButtons = () => [...document.querySelectorAll("[role=dialog]")].flatMap((d) => {
  const buttons = [...d.querySelectorAll("button")];
  const texts = buttons.map((b) => b.innerText.trim());
  if (!(d.getBoundingClientRect().width > 0 && texts.some((t) => /^(Huỷ|Hủy|Cancel)$/i.test(t)))) return [];
  return buttons.filter((b) => /^(Tôi đồng ý|I agree|Agree)$/i.test(b.innerText.trim()));
});
let consentClicks = 0, lastConsentClick = 0;
// True while a consent dialog is up: clicks the top one's Tôi đồng ý (at most once a second).
function agreeToConsent() {
  const buttons = consentAgreeButtons();
  if (!buttons.length) return false;
  if (Date.now() - lastConsentClick < 1000) return true;
  if (++consentClicks > 20) throw new Error(FLOW_CONSENT);
  lastConsentClick = Date.now();
  note(`agreeing to the image-rights dialog (${consentClicks})`);
  const box = buttons.at(-1).getBoundingClientRect();
  chrome.runtime.sendMessage({ type: "click", x: box.left + box.width / 2, y: box.top + box.height / 2 }).catch(() => null);
  return true;
}
const agentChip = () => [...document.querySelectorAll("button")].find((b) => b.getAttribute("aria-pressed") === "true" && (b.classList.contains("agent-mode-chip") || /^(Tác nhân|Agent)$/i.test(b.innerText.trim())));
const flowAgentOn = () => !!agentChip();
async function turnAgentOff() {
  // A first-use tip (Tôi hiểu) can sit over the composer.
  [...document.querySelectorAll("button")].find((b) => /^(check\s*)?(Tôi hiểu|Got it)$/i.test(b.innerText.trim()))?.click();
  await sleep(500);
  const chip = agentChip();
  if (!chip) return;
  const box = chip.getBoundingClientRect();
  await chrome.runtime.sendMessage({ type: "click", x: box.left + box.width / 2, y: box.top + box.height / 2 }).catch(() => null);
  await waitFor(() => !flowAgentOn(), 10000, "").catch(() => { throw new Error(FLOW_AGENT); });
}
const flowWelcome = () => [...document.querySelectorAll("[role=dialog]")].some((d) => {
  const texts = [...d.querySelectorAll("button")].map((b) => b.innerText.trim());
  return d.getBoundingClientRect().width > 0 && texts.some((t) => /^(Tiếp theo|Next)$/i.test(t)) && texts.some((t) => /^(Đăng xuất|Sign out)$/i.test(t));
});

// On Flow's home page: where its new-project button is, for the background to click.
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "new-project") return;
  const find = () => {
    if (flowWelcome()) throw new Error(FLOW_WELCOME);
    return [...document.querySelectorAll("button")].find((b) => /Dự án mới|New project/i.test(b.innerText) || (b.classList.contains("mat-mdc-fab") && /^add\b/.test(b.innerText.trim())));
  };
  waitFor(find, 30000, "nút Dự án mới của Flow (đã đăng nhập Google chưa?)").then(async (button) => {
    // The dialog can come a moment after the page.
    await sleep(1500);
    if (flowWelcome()) throw new Error(FLOW_WELCOME);
    button.scrollIntoView({ block: "center" });
    const box = button.getBoundingClientRect();
    sendResponse({ ok: true, x: box.left + box.width / 2, y: box.top + box.height / 2 });
  }).catch((error) => sendResponse({ ok: false, error: String(error.message || error) }));
  return true;
});
