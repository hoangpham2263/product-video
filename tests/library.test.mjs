import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createLibrary, SOURCES_URL } from "../src/library.mjs";

const manifest = { groups: [
  { kind: "products", name: "Nội thất", enabled: true, files: [{ name: "a.jpg" }, { name: "clip.mp4" }, { name: "../x.jpg" }] },
  { kind: "products", name: "Tắt", enabled: false, files: [{ name: "b.jpg" }] },
  { kind: "models", name: "Nữ", files: [{ name: "m.png" }] },
  { kind: "videos", name: "Mẫu", files: [{ name: "v.mp4" }] },
] };
const call = async (handle, method, path, body) => {
  const url = new URL(`http://x${path}`);
  const req = { method, async *[Symbol.asyncIterator]() { if (body) yield Buffer.from(JSON.stringify(body)); } };
  const res = { status: 0, data: null, writeHead(s) { this.status = s; }, end(t) { this.data = JSON.parse(t); } };
  const handled = await handle(req, res, url.pathname, url);
  return { handled, ...res };
};

test("each kind lists only its switched-on groups and their photos, with raw links", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "pv-lib-"));
  try {
    const handle = createLibrary({ workspace, base: SOURCES_URL, request: async () => new Response(JSON.stringify(manifest)) });
    const r = await call(handle, "GET", "/api/library?kind=products");
    assert.equal(r.status, 200);
    assert.deepEqual(r.data.groups.map((g) => [g.name, g.files.map((f) => f.name)]), [["Nội thất", ["a.jpg"]]]);
    assert.equal(r.data.groups[0].files[0].url, `${SOURCES_URL}/products/N%E1%BB%99i%20th%E1%BA%A5t/a.jpg`);
    assert.deepEqual((await call(handle, "GET", "/api/library?kind=models")).data.groups.map((g) => g.name), ["Nữ"]);
    assert.deepEqual((await call(handle, "GET", "/api/library?kind=videos")).data.groups.map((g) => g.files.map((f) => f.name)), [["v.mp4"]]);
    assert.equal((await call(handle, "GET", "/api/library?kind=other")).status, 400);
    assert.equal((await call(handle, "GET", "/api/other")).handled, false);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("a picked photo is downloaded once into workspace/library and its path returned", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "pv-lib-"));
  try {
    let downloads = 0;
    const handle = createLibrary({ workspace, request: async (url) => { downloads++; assert.match(url, /\/models\/N%E1%BB%AF\/m\.png$/); return new Response("png-bytes"); } });
    const first = await call(handle, "POST", "/api/library/pick", { kind: "models", group: "Nữ", name: "m.png" });
    assert.equal(first.status, 200);
    assert.equal(first.data.path, join(workspace, "library", "models", "Nữ", "m.png"));
    assert.equal(await readFile(first.data.path, "utf8"), "png-bytes");
    await call(handle, "POST", "/api/library/pick", { kind: "models", group: "Nữ", name: "m.png" });
    assert.equal(downloads, 1);
    for (const bad of [{ kind: "models", group: "..", name: "m.png" }, { kind: "models", group: "Nữ", name: "../m.png" }, { kind: "videos", group: "Mẫu", name: "v.jpg" }]) {
      assert.equal((await call(handle, "POST", "/api/library/pick", bad)).status, 400);
    }
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("offline, the list says so instead of failing", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "pv-lib-"));
  try {
    const handle = createLibrary({ workspace, request: async () => { throw new Error("offline"); } });
    const r = await call(handle, "GET", "/api/library?kind=products");
    assert.equal(r.status, 200);
    assert.deepEqual(r.data.groups, []);
    assert.match(r.data.error, /Không kết nối được kho ảnh/);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});
