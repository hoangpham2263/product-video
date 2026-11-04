// Helpers every site script (sites/<site>.js) shares; loaded first in each of their pages.
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// A step of the job, for the bridge's log (<hub>/workspace/logs/bridge.log).
const note = (stage) => chrome.runtime.sendMessage({ type: "progress", stage: `${location.host}: ${stage}` }).catch(() => {});

async function waitFor(check, timeoutMs, label) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    const value = await check();
    if (value) return value;
    await sleep(1000);
  }
  throw new Error(`Hết thời gian chờ: ${label}`);
}

function filesFromJob(job) {
  return (job.images || []).map((image) => {
    const bytes = Uint8Array.from(atob(image.data), (c) => c.charCodeAt(0));
    return new File([bytes], image.name, { type: image.mime });
  });
}

// Both composers attach images from a paste event, one file at a time.
async function pasteFiles(editor, files) {
  for (const file of files) {
    const transfer = new DataTransfer();
    transfer.items.add(file);
    editor.focus();
    editor.dispatchEvent(new ClipboardEvent("paste", { clipboardData: transfer, bubbles: true, cancelable: true }));
    await sleep(1500);
  }
}

// ProseMirror editors accept text through the same input path as typing.
// Select only the editor's own content; a document-wide selectAll would select the whole page.
function typePrompt(editor, text) {
  editor.focus();
  const range = document.createRange();
  range.selectNodeContents(editor);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
  document.execCommand("insertText", false, text);
  if (!editor.innerText.includes(text.slice(0, 20))) throw new Error("Không điền được prompt vào ô nhập.");
}

async function blobToBase64(blob) {
  const buffer = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  for (let i = 0; i < buffer.length; i += 0x8000) binary += String.fromCharCode(...buffer.subarray(i, i + 0x8000));
  return btoa(binary);
}

function onJob(handler) {
  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type !== "generate") return;
    handler(message.job).then(
      (result) => sendResponse({ ok: true, ...result }),
      (error) => sendResponse({ ok: false, error: String(error.message || error) }),
    );
    return true;
  });
}
