import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { causeOf, createBridge } from "./server.mjs";

const usage = join(await mkdtemp(join(tmpdir(), "bridge-usage-")), "ai-usage.jsonl");
async function start(fetchImpl, googleAccount = () => "", options = {}) {
  const server = createBridge({ fetchImpl, googleAccount, usage, ...options });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, base: `http://127.0.0.1:${server.address().port}`, ws: `ws://127.0.0.1:${server.address().port}` };
}

async function fakeExtension(url, answer) {
  const socket = new WebSocket(url, { origin: "chrome-extension://test" });
  socket.on("message", (data) => {
    const job = JSON.parse(data);
    socket.send(JSON.stringify({ type: "result", id: job.id, ...answer(job) }));
  });
  await new Promise((resolve) => socket.on("open", resolve));
  await new Promise((resolve) => setTimeout(resolve, 50));
  return socket;
}

test("forwards a job with reference images and writes the returned image", async () => {
  const { server, base, ws } = await start();
  const dir = await mkdtemp(join(tmpdir(), "bridge-"));
  await writeFile(join(dir, "ref.png"), Buffer.from([1, 2, 3]));
  let received;
  const socket = await fakeExtension(ws, (job) => { received = job; return { ok: true, data: Buffer.from("PNGDATA").toString("base64") }; });
  const output = join(dir, "out.png");
  const response = await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform: "chatgpt", prompt: "p", images: [join(dir, "ref.png")], output }) });
  assert.equal(response.status, 200);
  assert.equal(received.images.length, 1);
  assert.equal(received.images[0].mime, "image/png");
  assert.equal((await readFile(output)).toString(), "PNGDATA");
  socket.close(); server.close();
});

test("downloads signed URLs returned by Flow", async () => {
  const { server, base, ws } = await start(async (url) => ({ ok: url === "https://flow-content.google/image/x?Signature=s", arrayBuffer: async () => Buffer.from("FLOW") }));
  const dir = await mkdtemp(join(tmpdir(), "bridge-"));
  const socket = await fakeExtension(ws, () => ({ ok: true, url: "https://flow-content.google/image/x?Signature=s" }));
  const output = join(dir, "out.png");
  const response = await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform: "flow", prompt: "p", output }) });
  assert.equal(response.status, 200);
  assert.equal((await readFile(output)).toString(), "FLOW");
  socket.close(); server.close();
});

test("Flow and Gemini jobs carry the Google account chosen on Cấu hình; ChatGPT jobs do not", async () => {
  const { server, base, ws } = await start(undefined, () => "second@gmail.com");
  const dir = await mkdtemp(join(tmpdir(), "bridge-"));
  const seen = {};
  const socket = await fakeExtension(ws, (job) => { seen[job.platform] = job.account; return job.platform === "gemini" ? { ok: true, text: "t" } : { ok: true, data: Buffer.from("x").toString("base64") }; });
  for (const platform of ["gemini", "chatgpt"]) {
    const response = await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform, prompt: "p", output: join(dir, `${platform}.out`) }) });
    assert.equal(response.status, 200);
  }
  assert.equal(seen.gemini, "second@gmail.com");
  assert.equal(seen.chatgpt, "");
  socket.close(); server.close();
});

test("reports extension errors and rejects non-extension sockets", async () => {
  const { server, base, ws } = await start();
  const page = new WebSocket(ws, { origin: "https://evil.example" });
  await new Promise((resolve) => page.on("close", resolve));
  let response = await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform: "chatgpt", prompt: "p", output: "/tmp/x.png" }) });
  assert.equal(response.status, 503);
  const socket = await fakeExtension(ws, () => ({ ok: false, error: "ChatGPT chưa đăng nhập." }));
  response = await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform: "chatgpt", prompt: "p", output: "/tmp/x.png" }) });
  assert.equal(response.status, 502);
  assert.match((await response.json()).error, /đăng nhập/);
  socket.close(); server.close();
});

test("sends jobs side by side up to its limit and starts a session only when no job waits", async () => {
  const { server, base, ws } = await start(undefined, undefined, { parallel: 2, perSite: {} });
  const dir = await mkdtemp(join(tmpdir(), "bridge-"));
  let busy = 0, most = 0, sessions = 0;
  const socket = new WebSocket(ws, { origin: "chrome-extension://test" });
  socket.on("message", (data) => {
    const job = JSON.parse(data);
    if (job.type === "session") { sessions++; return socket.send(JSON.stringify({ type: "result", id: job.id, ok: true, closed: 2 })); }
    busy++; most = Math.max(most, busy);
    setTimeout(() => { busy--; socket.send(JSON.stringify({ type: "result", id: job.id, ok: true, text: job.prompt })); }, 100);
  });
  await new Promise((resolve) => socket.on("open", resolve));
  await new Promise((resolve) => setTimeout(resolve, 50));
  const post = (path, body) => fetch(`${base}${path}`, { method: "POST", body: body && JSON.stringify(body) });
  const runs = ["a", "b", "c"].map((p) => post("/generate", { platform: "gemini", prompt: p, output: join(dir, `${p}.txt`) }));
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal((await (await fetch(`${base}/status`)).json()).jobs, 3);
  assert.equal((await (await post("/session")).json()).skipped, "busy");
  for (const r of await Promise.all(runs)) assert.equal(r.status, 200);
  assert.equal(most, 2);
  assert.equal((await readFile(join(dir, "c.txt"), "utf8")), "c");
  assert.equal((await (await post("/session")).json()).closed, 2);
  assert.equal(sessions, 1);
  socket.close(); server.close();
});

test("a site with a limit of its own gets its jobs one at a time while another site's run beside them", async () => {
  const { server, base, ws } = await start(undefined, undefined, { parallel: 4, perSite: { gemini: 1 } });
  const dir = await mkdtemp(join(tmpdir(), "bridge-"));
  const busy = {}, most = {};
  const socket = new WebSocket(ws, { origin: "chrome-extension://test" });
  socket.on("message", (data) => {
    const job = JSON.parse(data);
    busy[job.platform] = (busy[job.platform] || 0) + 1;
    most[job.platform] = Math.max(most[job.platform] || 0, busy[job.platform]);
    setTimeout(() => { busy[job.platform]--; socket.send(JSON.stringify({ type: "result", id: job.id, ok: true, text: job.prompt })); }, 80);
  });
  await new Promise((resolve) => socket.on("open", resolve));
  await new Promise((resolve) => setTimeout(resolve, 50));
  const post = (platform, p) => fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform, prompt: p, output: join(dir, p) }) });
  const runs = [post("gemini", "a"), post("gemini", "b"), post("flow", "c"), post("flow", "d")];
  for (const r of await Promise.all(runs)) assert.equal(r.status, 200);
  assert.deepEqual(most, { gemini: 1, flow: 2 });
  socket.close(); server.close();
});

test("a job that waits too long for its turn says so", async () => {
  const server = createBridge({ queueMs: 50, usage, parallel: 1 });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const socket = new WebSocket(`ws://127.0.0.1:${server.address().port}`, { origin: "chrome-extension://test" });
  socket.on("message", () => {});
  await new Promise((resolve) => socket.on("open", resolve));
  await new Promise((resolve) => setTimeout(resolve, 50));
  const dir = await mkdtemp(join(tmpdir(), "bridge-"));
  const first = fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform: "gemini", prompt: "p", output: join(dir, "a"), timeoutSec: 1 }) });
  const second = await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform: "gemini", prompt: "p", output: join(dir, "b") }) });
  assert.equal(second.status, 504);
  assert.match((await second.json()).error, /chờ đến lượt/);
  first.catch(() => {}); socket.close(); server.closeAllConnections(); server.close();
});

test("every job is counted with its account, and a failure with its cause", async () => {
  const { server, base, ws } = await start(undefined, () => "second@gmail.com");
  const dir = await mkdtemp(join(tmpdir(), "bridge-"));
  const before = await readFile(usage, "utf8").catch(() => "");
  const socket = await fakeExtension(ws, (job) => (job.platform === "flow" ? { ok: false, error: "Flow: You've reached your daily limit" } : { ok: true, text: "t" }));
  for (const platform of ["gemini", "flow"]) await fetch(`${base}/generate`, { method: "POST", body: JSON.stringify({ platform, prompt: "p", output: join(dir, platform) }) });
  const lines = (await readFile(usage, "utf8")).slice(before.length).trim().split("\n").map((l) => JSON.parse(l));
  assert.deepEqual(lines.map((l) => [l.ai, l.kind, l.account, l.ok, l.cause]), [["gemini", "text", "second@gmail.com", true, undefined], ["flow", "image", "second@gmail.com", false, "QUOTA"]]);
  assert.equal(causeOf("Hết thời gian chờ: Flow tạo ảnh"), "AI_TIMEOUT");
  assert.equal(causeOf("ChatGPT chưa đăng nhập."), "AUTH");
  assert.equal(causeOf("Google Flow từ chối tạo ảnh: Không thành công Lượt tạo này có thể vi phạm các chính sách của chúng tôi."), "POLICY");
  socket.close(); server.close();
});
