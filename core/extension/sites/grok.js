// Grok Imagine (grok.com/imagine): an image or a video from the job's images (job.kind).
//   image  every image attached to the composer of /imagine in Image mode, the prompt, Submit. Grok opens the new
//          post (/imagine/post/<id>); its image is assets.grok.com/.../generated/<id>/image.jpg.
//   video  the same composer in Video mode: image 1 attached is the first frame, image 2 the last (Add last frame), then
//          length, resolution and sound (job.options), the prompt, Submit. The video is .../generated/<id>/generated_video.mp4.
// Add last frame opens a file chooser: sites/grok-main.js, in the page's own world, hands it the file instead.
// Grok's buttons take synthetic clicks and its menus (Radix) open on pointerdown. Escape leaves a post: never sent.
const visible = (el) => { const box = el.getBoundingClientRect(); return box.width > 0 && box.height > 0; };
const lastOf = (selector) => [...document.querySelectorAll(selector)].filter(visible).at(-1);
const countOf = (selector) => [...document.querySelectorAll(selector)].filter(visible).length;
const editor = () => lastOf('form [contenteditable="true"]');
const postId = () => location.pathname.match(/^\/imagine\/post\/([\w-]+)/)?.[1] || "";
const GROK_SIGN_IN = "Grok chưa đăng nhập trong Chrome. Mở grok.com trong Chrome, đăng nhập rồi chạy lại.";

async function ready() {
  const signedIn = () => !!document.querySelector('button[aria-label^="Account menu"]');
  const signInLink = () => [...document.querySelectorAll("a, button")].some((b) => visible(b) && /^(Sign in|Log in|Sign up|Đăng nhập)$/i.test(b.innerText.trim()));
  await waitFor(() => {
    if (signInLink() && !signedIn()) throw new Error(GROK_SIGN_IN);
    return signedIn() && editor();
  }, 30000, "ô nhập của Grok Imagine (đã đăng nhập grok.com chưa?)");
}

// Image, Video or Agent. The radio can be there before the page answers to it: clicked again until it takes.
async function setMode(name) {
  for (let i = 0; i < 20; i++) {
    const radio = lastOf(`[role="radio"][aria-label="${name}"]`);
    if (radio?.getAttribute("aria-checked") === "true" && (name !== "Video" || lastOf('button[aria-label="Video duration"]'))) return;
    radio?.click();
    await sleep(800);
  }
  const labels = [...(editor()?.closest("form") || document).querySelectorAll("button")].filter(visible).map((b) => b.getAttribute("aria-label") || b.innerText.trim()).filter(Boolean);
  throw new Error(`Không chuyển được Grok sang chế độ ${name} (trang rộng ${innerWidth}px; nút: ${labels.join(", ").slice(0, 300)}).`);
}

// One choice of a menu (Video duration, Video resolution): the first of `wanted` it offers. Not offered: left as it is.
async function pickMenu(label, wanted) {
  const button = lastOf(`button[aria-label="${label}"]`);
  if (!button) return note(`${label}: no button`);
  if (wanted.includes(button.innerText.trim())) return;
  button.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, button: 0, pointerType: "mouse" }));
  await sleep(600);
  const items = [...document.querySelectorAll('[role="menu"] [role="menuitemradio"]')].filter(visible);
  const item = wanted.map((w) => items.find((i) => i.innerText.trim().split("\n")[0] === w)).find(Boolean);
  if (item) item.click();
  else button.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, button: 0, pointerType: "mouse" }));
  await sleep(600);
  note(`${label}: ${lastOf(`button[aria-label="${label}"]`)?.innerText.trim()} (wanted ${wanted[0]})`);
}

async function setAudio(on) {
  for (let i = 0; i < 3; i++) {
    const button = lastOf('button[aria-label="Video audio"]');
    if (!button || (button.getAttribute("aria-pressed") === "true") === on) return;
    button.click();
    await sleep(500);
  }
}

// A refusal or a spent quota shows as text on the page (a toast, a dialog or the post itself).
function pageError() {
  const leaves = [...document.querySelectorAll("[data-sonner-toast], [role=alert], [role=status], [role=dialog], main *")]
    .filter((e) => visible(e) && e.children.length === 0 && !e.closest("form"));
  for (const el of leaves) {
    const text = el.textContent.replace(/\s+/g, " ").trim();
    if (text.length > 200) continue;
    if (/\b(content )?moderated\b|violat(es|ion)|against (our|the) (policy|guidelines)/i.test(text)) return `Grok từ chối tạo (kiểm duyệt): ${text}`;
    if (/rate limit|limit reached|reached (your|the) (daily |usage )?limit|out of (free )?(credits|generations)|upgrade to (continue|supergrok)/i.test(text)) return `Grok hết lượt (giới hạn): ${text}`;
  }
  return "";
}

async function submit(button, kind, timeoutMs) {
  const before = postId();
  // A video made from an attached frame can keep the frame's post in the address and get an id of its own: the result
  // is then the video that was not on the page before the click.
  const videos = () => [...document.querySelectorAll("video")].map((v) => v.currentSrc || v.src || v.querySelector("source")?.src || "").filter((src) => src.includes("/generated_video"));
  const videosBefore = new Set(videos().map((src) => src.split("?")[0]));
  button.click();
  // Grok opens the result's own post: a new id in the address, first a temporary one (tmp_...), then its own.
  const fresh = () => { const id = postId(); return id && id !== before && !id.startsWith("tmp_") ? id : ""; };
  const id = await waitFor(() => {
    const error = pageError();
    if (error) throw new Error(error);
    return fresh();
  }, 120000, "Grok bắt đầu tạo");
  note(`started ${kind} ${id}`);
  const find = (id = fresh()) => id && (kind === "video"
    ? videos().find((src) => src.includes(`/generated/${id}/`)) || videos().find((src) => !videosBefore.has(src.split("?")[0]))
    :[...document.images].find((img) => img.src.includes(`/generated/${id}/`) && img.complete && img.naturalWidth > 256)?.src);
  const url = await waitFor(() => {
    const error = pageError();
    if (error) throw new Error(error);
    return find();
  }, timeoutMs, kind === "video" ? "Grok tạo video" : "Grok tạo ảnh");
  // An image can show once at low detail first: what is there a moment later is the result.
  await sleep(1500);
  return { url: find() || url, source: location.href };
}

// Images into the composer of /imagine (its own file input, which takes several); each shows with a Remove image button.
async function attach(files) {
  const input = editor().closest("form").querySelector('input[type="file"]');
  const transfer = new DataTransfer();
  files.forEach((f) => transfer.items.add(f));
  input.files = transfer.files;
  input.dispatchEvent(new Event("change", { bubbles: true }));
  await waitFor(() => countOf('form button[aria-label="Remove image"]') >= files.length, 60000, "tải ảnh lên Grok");
  note(`attached ${files.length} images`);
}

async function generateImage(job) {
  await ready();
  await setMode("Image");
  const files = filesFromJob(job);
  if (files.length) await attach(files);
  if (job.options?.aspect) await pickMenu("Aspect Ratio", [job.options.aspect]);
  typePrompt(editor(), job.prompt);
  const button = await waitFor(() => { const b = lastOf('form button[aria-label="Submit"]'); return b && !b.disabled && b; }, 30000, "nút gửi của Grok");
  return submit(button, "image", (job.timeoutSec || 300) * 1000);
}

async function generateVideo(job) {
  await ready();
  const [first, last] = filesFromJob(job);
  if (!first) throw new Error("Video của Grok cần ảnh khung đầu.");
  // Video mode first: an image attached then is the video's first frame, and Add last frame shows beside it.
  await setMode("Video");
  await attach([first]);
  if (last) {
    const image = job.images[1];
    const heard = (kind) => new Promise((resolve) => window.addEventListener("message", function on(event) {
      if (event.origin === location.origin && event.data?.toolsHub === kind) { window.removeEventListener("message", on); resolve(true); }
    }));
    const armed = heard("armed"), used = heard("file-used");
    window.postMessage({ toolsHub: "arm-file", file: { name: image.name, type: image.mime, data: image.data } }, location.origin);
    note(`last frame armed: ${await Promise.race([armed, sleep(3000).then(() => false)])}`);
    const add = await waitFor(() => lastOf('button[aria-label="Add last frame"]'), 15000, "").catch(() => {
      const labels = [...(editor()?.closest("form") || document).querySelectorAll("button")].filter(visible).map((b) => b.getAttribute("aria-label") || b.innerText.trim()).filter(Boolean);
      throw new Error(`Không thấy nút Add last frame của Grok (${location.pathname}; nút: ${labels.join(", ").slice(0, 300)}).`);
    });
    const removes = countOf('button[aria-label="Remove image"]');
    add.click();
    note(`last frame handed to the page: ${await Promise.race([used, sleep(10000).then(() => false)])}`);
    // Without it the video is still made, from the first frame alone (the run starts the next clip where this one ends).
    const added = await waitFor(() => !lastOf('button[aria-label="Add last frame"]') || countOf('button[aria-label="Remove image"]') > removes, 20000, "").catch(() => false);
    note(added ? "last frame added" : `last frame not added (Remove image ${countOf('button[aria-label="Remove image"]')}), making the video from the first frame`);
  }
  const options = job.options || {};
  if (options.seconds) await pickMenu("Video duration", [`${options.seconds}s`]);
  // The resolution wanted, else the next lower one Grok offers (with a last frame it may not offer the highest).
  const resolutions = ["1080p", "720p", "480p"];
  if (options.resolution) await pickMenu("Video resolution", resolutions.slice(Math.max(0, resolutions.indexOf(options.resolution))));
  if (typeof options.audio === "boolean") await setAudio(options.audio);
  // Grok keeps the last aspect used: set every time, so the video has the run's shape, not the page's.
  if (options.aspect) await pickMenu("Aspect Ratio", [options.aspect]);
  typePrompt(editor(), job.prompt);
  const button = await waitFor(() => { const b = lastOf('form button[aria-label="Submit"]') || lastOf('button[aria-label="Make video"]'); return b && !b.disabled && b; }, 30000, "nút gửi của Grok");
  return submit(button, "video", (job.timeoutSec || 900) * 1000);
}

onJob((job) => (job.kind === "video" ? generateVideo(job) : generateImage(job)));
