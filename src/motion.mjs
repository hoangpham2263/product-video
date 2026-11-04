// The camera move of a stretch of the sample video, from ffmpeg's vidstabdetect (.trf): every frame lists local motions
// (LM dx dy x y ...): how far the patch at (x, y) is from where it was in the frame before, measured backwards (checked
// 04/11/2026 against the frames: a picture sliding left gives dx > 0), so the signs are turned here. Per frame, a fit of
//   dx = tx + s * (x - cx),  dy = ty + s * (y - cy)
// gives the shift of the whole picture (tx, ty) and its growth (s, zoom). Summed over the stretch, they say how the
// camera moved: the picture sliding left means the camera went right; growing means it pushed in.
//   node src/motion.mjs <file.trf> <width> <height> <fps> <start s> <end s>   ->  { panX, panY, zoom, seconds }
//   panX, panY: picture shift as a share of its width/height (+ right/down); zoom: end size / start size.
import { readFileSync } from "node:fs";

export function readTrf(text) {
  const frames = [];
  for (const line of text.split(/\r?\n/)) {
    const m = /^Frame (\d+) \(List \d+ \[(.*)\]\)/.exec(line);
    if (!m) continue;
    const motions = [...m[2].matchAll(/LM (-?\d+) (-?\d+) (\d+) (\d+) \d+ ([\d.]+) ([\d.]+)/g)].map((x) => ({
      dx: -x[1], dy: -x[2], x: +x[3], y: +x[4], contrast: +x[5], match: +x[6],
    }));
    frames[+m[1] - 1] = motions;
  }
  return frames;
}

// One frame's (tx, ty, s) by least squares; outliers (a moving object, a bad match) dropped once.
function fitFrame(motions, cx, cy) {
  const fit = (list) => {
    if (list.length < 4) return null;
    const mx = list.reduce((a, m) => a + m.dx, 0) / list.length, my = list.reduce((a, m) => a + m.dy, 0) / list.length;
    const rx = list.reduce((a, m) => a + (m.x - cx), 0) / list.length, ry = list.reduce((a, m) => a + (m.y - cy), 0) / list.length;
    let num = 0, den = 0;
    for (const m of list) { const ux = m.x - cx - rx, uy = m.y - cy - ry; num += ux * (m.dx - mx) + uy * (m.dy - my); den += ux * ux + uy * uy; }
    const s = den ? num / den : 0;
    return { tx: mx - s * rx, ty: my - s * ry, s };
  };
  const first = fit(motions);
  if (!first) return { tx: 0, ty: 0, s: 0 };
  const err = (m) => Math.hypot(m.dx - (first.tx + first.s * (m.x - cx)), m.dy - (first.ty + first.s * (m.y - cy)));
  const errors = motions.map(err).sort((a, b) => a - b);
  const limit = Math.max(1, errors[Math.floor(errors.length * 0.7)] * 2);
  return fit(motions.filter((m) => err(m) <= limit)) || first;
}

export function cameraMove(frames, width, height, fps, start, end) {
  // frames[i] is the step from frame i - 1 to frame i: from..to takes steps from + 1 to to, both ends included.
  const last = Math.max(0, frames.length - 1);
  const from = Math.min(last, Math.max(0, Math.round(start * fps))), to = Math.max(from, Math.min(last, Math.round(end * fps)));
  let panX = 0, panY = 0, zoom = 1;
  for (let i = from + 1; i <= to; i++) {
    const f = fitFrame(frames[i] || [], width / 2, height / 2);
    panX += f.tx / width; panY += f.ty / height; zoom *= 1 + f.s;
  }
  return { panX: +panX.toFixed(4), panY: +panY.toFixed(4), zoom: +zoom.toFixed(4), seconds: +((to - from) / fps).toFixed(3) };
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, "/").split("/").pop())) {
  const [file, width, height, fps, start, end] = process.argv.slice(2);
  console.log(JSON.stringify(cameraMove(readTrf(readFileSync(file, "utf8")), +width, +height, +fps, +start, +end)));
}
