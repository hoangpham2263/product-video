// Cấu hình and Cập nhật for every page the Tools Hub menu serves, on macOS and Windows (the menu and web tools): buttons
// at the top right, where Product Review has its own; Cập nhật turns green with the version once a newer one is out.
// Both work through the menu server (hub/picker.mjs, hub/setup/config-api.mjs). A page opened as a file has no server
// to ask, so no buttons.
(() => {
  // A page laid out for a minimum size (<body data-fit="960x680">) scales down to fit a smaller window instead of
  // being squeezed or cut off, as Product Review does; below 60% it stops shrinking and scrolls. Its height, a
  // 100vh layout, is set to the scaled window's.
  const fit = /^(\d+)x(\d+)$/.exec(document.body?.dataset.fit || "");
  if (fit) {
    const [w, h] = [Number(fit[1]), Number(fit[2])];
    const apply = () => {
      const zoom = Math.max(0.6, Math.min(1, innerWidth / w, innerHeight / h));
      document.documentElement.style.zoom = zoom === 1 ? "" : String(zoom);
      document.body.style.height = zoom === 1 ? "" : `${Math.max(h, innerHeight / zoom)}px`;
      document.body.style.overflow = innerWidth / zoom < w - 1 || innerHeight / zoom < h - 1 ? "auto" : "";
      document.documentElement.style.overflow = document.body.style.overflow;
    };
    apply();
    addEventListener("resize", apply);
  }
  if (!location.protocol.startsWith("http")) return;
  const header = document.querySelector("header");
  if (!header) return;
  const btn = Object.assign(document.createElement("button"), { type: "button", className: "btn update", textContent: "Cập nhật" });
  const config = Object.assign(document.createElement("button"), { type: "button", className: "btn config", textContent: "Cấu hình" });
  // Tải lại: the menu starts again on the files as they are now and the page loads afresh (after an update, or when
  // the page looks out of date).
  const reload = Object.assign(document.createElement("button"), { type: "button", className: "btn reload", textContent: "Tải lại" });
  header.append(reload, config, btn);
  reload.onclick = async () => {
    reload.disabled = true;
    reload.textContent = "Đang tải lại…";
    const r = await fetch("/api/reload", { method: "POST" }).catch(() => null);
    if (!r || !r.ok) return location.reload();
    const wait = () => fetch("/api/root").then((x) => (x.ok ? location.reload() : setTimeout(wait, 400))).catch(() => setTimeout(wait, 400));
    setTimeout(wait, 900);
  };
  // The window title carries the installed version, as Product Review's does: "Grok Video Prompt v2.0.21".
  fetch("/api/root").then((r) => r.json()).then((r) => { if (r.version && !document.title.endsWith(r.version)) document.title = `${document.title} ${r.version}`; }).catch(() => {});
  config.onclick = showSetup;
  // The menu says whether Cấu hình is done: every step but the quota (which only reads what is left) must be OK.
  // Cấu hình turns green while something is missing; coming back from it checks again.
  const status = document.getElementById("setupStatus");
  const STEP_NAMES = { drive: "mật khẩu app", node: "Node.js", codex: "Codex", login: "đăng nhập ChatGPT" };
  let setupRequest;
  function requestSetup() {
    if (setupRequest) return setupRequest;
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), 50000);
    setupRequest = fetch('/api/setup', { method: 'POST', signal: abort.signal, cache: 'no-store' })
      .then(async response => {
        const report = await response.json();
        if (!response.ok) return { error: report.error || 'Không kiểm tra được cấu hình. Bấm Kiểm tra lại.' };
        if (!Array.isArray(report.Steps) || [...Object.keys(STEP_NAMES), 'quota'].some(id => !report.Steps.some(step => step.Id === id))) return { error: 'Kết quả cấu hình chưa đầy đủ. Bấm Kiểm tra lại.' };
        return report;
      })
      .catch(error => ({ error: error.name === 'AbortError' ? 'Kiểm tra cấu hình quá thời gian. Bấm Kiểm tra lại.' : 'Mất kết nối với app. Đóng và mở lại Tools Hub rồi kiểm tra lại.' }))
      .finally(() => { clearTimeout(timer); setupRequest = null; });
    return setupRequest;
  }
  async function refreshStatus() {
    if (!status) return;
    status.className = "setup-status";
    status.innerHTML = `<span class="mark">○</span><span class="text muted">Đang kiểm tra cấu hình…</span>`;
    const report = await requestSetup();
    const steps = [].concat(report?.Steps || []);
    if (!steps.length) { status.innerHTML = `<span class="mark">!</span><span class="text">Chưa kiểm tra được cấu hình. Bấm Cấu hình để xem.</span>`; return; }
    const missing = steps.filter((s) => s.Id in STEP_NAMES && s.State !== "ok" && s.State !== "warn").map((s) => STEP_NAMES[s.Id]);
    const done = !missing.length;
    status.className = `setup-status ${done ? "ok" : "todo"}`;
    status.innerHTML = done
      ? `<span class="mark">✔</span><span class="text">Đã cấu hình đủ. Các công cụ sẵn sàng dùng.</span>`
      : `<span class="mark">✖</span><span class="text">Chưa cấu hình xong: còn thiếu ${missing.join(", ")}. Cấu hình đủ rồi mới dùng được các công cụ.</span><button class="btn primary" type="button">Cấu hình ngay</button>`;
    status.querySelector("button")?.addEventListener("click", showSetup);
    config.classList.toggle("primary", !done);
  }
  refreshStatus();
  let next = "", current = "";
  const show = () => { btn.textContent = next ? `Cập nhật ${next}` : "Cập nhật"; btn.classList.toggle("primary", !!next); };
  const check = () => fetch("/api/update-check").then((r) => (r.ok ? r.json() : Promise.reject())).then((r) => { next = r.next || ""; current = r.current || ""; show(); return true; }).catch(() => false);
  setTimeout(check, 3000);
  setInterval(check, 6 * 3600 * 1000);

  // Same dialog as Product Review's (Show-UpdateDialog): check, then download and install with a running bar.
  btn.onclick = async () => {
    const shade = Object.assign(document.createElement("div"), { className: "shade" });
    shade.innerHTML = `<div class="dialog" role="dialog" aria-label="Cập nhật"><div class="status"></div><div class="bar"><span></span></div><div class="actions"><button class="btn primary" type="button" hidden>Cập nhật</button><button class="btn" type="button">Đóng</button></div></div>`;
    document.body.append(shade);
    const [status, bar, go, close] = [".status", ".bar", ".btn.primary", ".btn:not(.primary)"].map((s) => shade.querySelector(s));
    close.onclick = () => { if (!close.disabled) shade.remove(); };
    status.textContent = "Đang kiểm tra bản mới…";
    if (!(await check())) { bar.hidden = true; status.textContent = "Không kiểm tra được bản mới. Kiểm tra mạng rồi thử lại."; return; }
    bar.hidden = true;
    if (!next) { status.textContent = `Đang dùng bản mới nhất (${current || "bản hiện tại"}).`; return; }
    status.textContent = `Có phiên bản mới ${next} (đang dùng ${current || "bản hiện tại"}).`;
    go.hidden = false; go.focus();
    go.onclick = async () => {
      status.textContent = `Đang tải và cài phiên bản ${next}…`;
      bar.hidden = false; go.hidden = true; close.disabled = true;
      const r = await fetch("/api/update", { method: "POST" }).catch(() => null);
      if (!r || !r.ok) {
        bar.hidden = true; close.disabled = false; go.textContent = "Thử lại"; go.hidden = false;
        status.textContent = "Chưa cập nhật được. Kiểm tra mạng rồi thử lại.";
        return;
      }
      // The menu restarts on the new files; the page reloads once it answers again.
      status.textContent = "Đã cập nhật. Đang mở lại…";
      const wait = () => fetch("/api/root").then((x) => (x.ok ? location.reload() : setTimeout(wait, 500))).catch(() => setTimeout(wait, 500));
      setTimeout(wait, 1200);
    };
  };

  // Cấu hình is a page of its own (hub/setup/page.html), shared by the menu and every tool; it comes back here.
  function showSetup() { location.href = `/setup?back=${encodeURIComponent(location.pathname + location.search)}`; }
})();
