// Gemini (gemini.google.com): attach the images, type the prompt, send, then return the reply's text once it has
// finished. Used for the workflow's text steps (Viết review: Gemini web); a plain click sends here. Every job runs in
// a temporary chat (Cuộc trò chuyện tạm thời), which Gemini keeps out of the history, so a run leaves no chats behind.
function geminiReplyText(markdown) {
  // Code blocks carry a language label and buttons; keep only their code.
  const copy = markdown.cloneNode(true);
  // Source chips (an attached image's file name, a cited page) sit inside the reply's text; they are not the answer.
  copy.querySelectorAll("sources-carousel-inline, source-inline-chip").forEach((chip) => chip.remove());
  for (const block of copy.querySelectorAll("code-block, .code-block")) {
    const code = block.querySelector("code");
    block.replaceWith(document.createTextNode(`\n${code ? code.textContent : block.textContent}\n`));
  }
  document.body.append(copy);
  Object.assign(copy.style, { position: "fixed", left: "-10000px", top: "0", width: "800px" });
  const text = copy.innerText;
  copy.remove();
  return text.trim();
}

// The temporary-chat button by the composer; on, Gemini shows its temporary-chat card over an empty chat.
const temporaryOn = () => !!document.querySelector(".temporary-chat-card");
async function temporaryChat() {
  if (temporaryOn()) return;
  const button = await waitFor(() => [...document.querySelectorAll("button")].find((b) => /^(Cuộc trò chuyện tạm thời|Temporary chat)$/i.test(b.getAttribute("aria-label") || "")), 15000, "").catch(() => null);
  if (!button) { note("no temporary-chat button: a normal chat"); return; }
  button.click();
  if (!(await waitFor(temporaryOn, 10000, "").catch(() => false))) note("temporary chat did not turn on: a normal chat");
}

async function generateGemini(job) {
  await waitFor(() => document.querySelector('.ql-editor[contenteditable="true"]'), 30000, "ô nhập Gemini (đã đăng nhập Google chưa?)");
  await temporaryChat();
  const editor = await waitFor(() => document.querySelector('.ql-editor[contenteditable="true"]'), 30000, "ô nhập Gemini (đã đăng nhập Google chưa?)");
  const before = document.querySelectorAll("model-response").length;
  const files = filesFromJob(job);
  await pasteFiles(editor, files);
  typePrompt(editor, job.prompt);
  // The send button stays off while attachments upload.
  const send = await waitFor(() => {
    // The send control is a gem-icon-button.send-button: "submit" with text to send, "stop" while answering.
    const button = document.querySelector(".send-button.submit button");
    return button && !button.disabled && button.getAttribute("aria-disabled") !== "true" ? button : null;
  }, 180000, "tải ảnh đính kèm lên Gemini");
  send.click();

  // Finished: a new reply, no stop button, not busy, and its text unchanged for two checks in a row.
  let last = "";
  const markdown = await waitFor(() => {
    const replies = document.querySelectorAll("model-response");
    if (replies.length <= before) return null;
    const md = replies[replies.length - 1].querySelector(".markdown");
    if (!md || md.getAttribute("aria-busy") === "true" || document.querySelector(".send-button.stop")) return null;
    const text = md.innerText.trim();
    if (!text || text !== last) { last = text; return null; }
    return md;
  }, (job.timeoutSec || 300) * 1000, "Gemini trả lời");
  return { text: geminiReplyText(markdown), source: location.href };
}

onJob(generateGemini);
