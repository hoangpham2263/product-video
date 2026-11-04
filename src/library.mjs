// Kho ảnh: the public GitHub repo hoangpham2263/product-video-sources. manifest.json lists its groups, each of one kind
// (products, models, videos) with its files; a file is <kind>/<group>/<name>. The window shows a kind's switched-on
// groups with raw links as thumbnails; a picked photo or video is downloaded once into workspace/library/<kind>/<group>/
// and its local path goes into the job, as an uploaded one does. A video's plan (its shots and angles, in the manifest)
// is saved beside it as <video>.json, where the run reads it. PV_SOURCES_URL points tests at a local copy.
//   GET  /api/library?kind=products|models|videos{ groups: [{ name, files: [{ name, url, local }] }] } or { error }
//   POST /api/library/pick { kind, group, name }   { path }
import { createWriteStream, existsSync } from "node:fs";
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { join, resolve, sep } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

export const SOURCES_URL = "https://raw.githubusercontent.com/hoangpham2263/product-video-sources/main";
const FILES = { products: /\.(png|jpe?g|webp)$/i, models: /\.(png|jpe?g|webp)$/i, videos: /\.(mp4|mov|webm)$/i };
const KINDS = Object.keys(FILES);
const safe = (s) => typeof s === "string" && s.length > 0 && s.length <= 200 && !/[\\/]|^\.\.?$/.test(s);

export function createLibrary({ workspace, base = process.env.PV_SOURCES_URL || SOURCES_URL, request = fetch }) {
  const folder = join(workspace, "library");
  const fileUrl = (kind, group, name) => `${base}/${kind}/${encodeURIComponent(group.normalize("NFC"))}/${encodeURIComponent(name)}`;
  const localPath = (kind, group, name) => {
    const path = resolve(folder, kind, group.normalize("NFC"), name);
    return path.startsWith(resolve(folder) + sep) ? path : "";
  };
  // The manifest, read again after a minute.
  let cache = null;
  const manifest = async () => {
    if (cache && Date.now() - cache.at < 60000) return cache.data;
    const r = await request(`${base}/manifest.json`, { cache: "no-store", signal: AbortSignal.timeout(30000) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const data = await r.json();
    cache = { at: Date.now(), data };
    return data;
  };
  const groups = async (kind) => [].concat((await manifest()).groups || [])
    .filter((g) => g.kind === kind && g.enabled !== false && safe(g.name))
    .map((g) => ({
      name: g.name.normalize("NFC"),
      files: [].concat(g.files || []).filter((f) => safe(f.name) && FILES[kind].test(f.name)).map((f) => {
        const local = localPath(kind, g.name, f.name);
        return { name: f.name, url: fileUrl(kind, g.name, f.name), local: local && existsSync(local) ? local : "" };
      }),
    }));
  const json = (res, status, data) => { res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }); res.end(JSON.stringify(data)); };
  const body = async (req) => { const chunks = []; for await (const c of req) chunks.push(c); try { return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"); } catch { return {}; } };

  return async function handle(req, res, path, url) {
    if (path === "/api/library" && req.method === "GET") {
      const kind = url.searchParams.get("kind");
      if (!KINDS.includes(kind)) { json(res, 400, { error: "Loại kho không hợp lệ." }); return true; }
      try { json(res, 200, { groups: await groups(kind) }); }
      catch { json(res, 200, { groups: [], error: "Không kết nối được kho ảnh (mạng). Thử lại sau." }); }
      return true;
    }
    if (path === "/api/library/pick" && req.method === "POST") {
      const { kind, group, name } = await body(req);
      if (!KINDS.includes(kind) || !safe(group) || !safe(name) || !FILES[kind].test(name)) { json(res, 400, { error: "Ảnh không hợp lệ." }); return true; }
      const file = localPath(kind, group, name);
      if (!file) { json(res, 400, { error: "Ảnh không hợp lệ." }); return true; }
      if (!existsSync(file)) {
        try {
          const r = await request(fileUrl(kind, group, name), { signal: AbortSignal.timeout(120000) });
          if (!r.ok || !r.body) throw new Error(`HTTP ${r.status}`);
          await mkdir(resolve(file, ".."), { recursive: true });
          await pipeline(Readable.fromWeb(r.body), createWriteStream(`${file}.part`));
          await rename(`${file}.part`, file);
        } catch {
          await rm(`${file}.part`, { force: true });
          json(res, 502, { error: "Chưa tải được tệp từ kho. Kiểm tra mạng rồi thử lại." });
          return true;
        }
      }
      if (kind === "videos") {
        const entry = [].concat((await manifest().catch(() => ({}))).groups || []).find((g) => g.kind === kind && g.name.normalize("NFC") === group.normalize("NFC"))?.files?.find((f) => f.name === name);
        if (entry?.plan) await writeFile(`${file}.json`, JSON.stringify(entry.plan));
        else await rm(`${file}.json`, { force: true });
      }
      json(res, 200, { path: file });
      return true;
    }
    return false;
  };
}
