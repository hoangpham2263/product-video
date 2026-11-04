// ChatGPT: submit through the composer, then read the result with the page's own GET APIs. The conversation the job
// made is then removed from the history (as the page's own Xoá does), so a run leaves no chats behind.
async function chatgptAuth() {
  const session = await fetch("/api/auth/session", { credentials: "include" }).then((r) => r.json());
  if (!session.accessToken) throw new Error("ChatGPT chưa đăng nhập.");
  return { Authorization: `Bearer ${session.accessToken}` };
}

async function generateChatgpt(job) {
  const startedAt = Date.now() / 1000;
  const editor = await waitFor(() => document.querySelector('.ProseMirror[contenteditable="true"]'), 30000, "ô nhập ChatGPT");
  const form = editor.closest("form");
  const files = filesFromJob(job);
  // Pasting is the attach path the composer handles for every file type it accepts.
  await pasteFiles(editor, files);
  if (files.length) await waitFor(() => form.querySelectorAll("img").length >= files.length, 120000, "đính kèm ảnh ChatGPT");
  typePrompt(editor, job.prompt);
  // The send button stays disabled until every attachment has uploaded.
  const send = await waitFor(() => {
    const button = form.querySelector('button[type="submit"]');
    return button && !button.disabled ? button : null;
  }, 180000, "tải ảnh đính kèm");
  send.click();

  const conversationId = await waitFor(() => location.pathname.match(/^\/c\/([\w-]+)/)?.[1], 60000, "mở cuộc trò chuyện");
  const headers = await chatgptAuth();
  const item = await waitFor(async () => {
    const list = await fetch("/backend-api/my/recent/image_gen?limit=10", { headers, credentials: "include" }).then((r) => r.json());
    return (list.items || []).find((i) => i.conversation_id === conversationId && i.created_at >= startedAt - 5 && !i.output_blocked);
  }, (job.timeoutSec || 600) * 1000, "ChatGPT tạo ảnh");
  const response = await fetch(item.url, { credentials: "include" });
  if (!response.ok) throw new Error(`Tải ảnh ChatGPT lỗi ${response.status}`);
  const blob = await response.blob();
  await fetch(`/backend-api/conversation/${conversationId}`, { method: "PATCH", credentials: "include", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify({ is_visible: false }) })
    .then((r) => note(r.ok ? "conversation removed" : `conversation not removed (${r.status})`), () => note("conversation not removed"));
  return { mime: blob.type || "image/png", data: await blobToBase64(blob), source: `https://chatgpt.com/c/${conversationId}` };
}

onJob(generateChatgpt);
