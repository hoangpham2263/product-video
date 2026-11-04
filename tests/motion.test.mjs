import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { readTrf, cameraMove } from "../src/motion.mjs";

// tests/fixtures/natural-close-to-wide-0-5s.trf: vidstabdetect as src/video.ps1 runs it (fps=5, scale=720:-2,
// shakiness=8:accuracy=15:stepsize=4) on product-video-sources videos/.../natural-product-close-to-wide-01.mp4 (960x960),
// frames 1-26 (0-5.2 s), every 4th local motion kept to stay small. Its plan: 0-3 s as-photo (pushes in), 3-5.25 s
// detail sliding along the wood.
const fixture = fileURLToPath(new URL("./fixtures/natural-close-to-wide-0-5s.trf", import.meta.url));
const motion = fileURLToPath(new URL("../src/motion.mjs", import.meta.url));
// A .trf frame line from local motions as vidstab writes them: LM dx dy x y size contrast match.
const frame = (n, list) => `Frame ${n} (List ${list.length} [${list.map(([dx, dy, x, y]) => `(LM ${dx} ${dy} ${x} ${y} 80 0.700000 2.000000)`).join(",")}])`;
const grid = (f) => { const list = []; for (const x of [120, 240, 360, 480, 600]) for (const y of [120, 240, 360, 480, 600]) list.push([...f(x, y), x, y]); return list; };
const trf = (frames) => ["VID.STAB 1", "#      accuracy = 15", "Frame 1 (List 0 [])", ...frames.map((f, i) => frame(i + 2, f))].join("\r\n");

test("readTrf reads every local motion, signs turned, CRLF or not", () => {
  const text = trf([[[3, -2, 146, 574], [-1, 0, 467, 253]]]);
  for (const t of [text, text.replace(/\r\n/g, "\n")]) {
    const frames = readTrf(t);
    assert.equal(frames.length, 2);
    assert.deepEqual(frames[0], []);
    assert.deepEqual(frames[1], [{ dx: -3, dy: 2, x: 146, y: 574, contrast: 0.7, match: 2 }, { dx: 1, dy: -0, x: 467, y: 253, contrast: 0.7, match: 2 }]);
  }
});

test("a picture sliding left (vidstab dx > 0) reads as panX < 0: the camera went right", () => {
  const frames = readTrf(trf(Array.from({ length: 10 }, () => grid(() => [4, 0]))));
  const move = cameraMove(frames, 720, 720, 5, 0, 2.2);
  assert.equal(move.panX, -0.0556); // 10 steps of 4 px / 720
  assert.equal(move.panY, 0);
  assert.equal(move.zoom, 1);
  assert.equal(move.seconds, 2); // the file ends at frame 10 (2 s)
  assert.equal(cameraMove(readTrf(trf(Array.from({ length: 10 }, () => grid(() => [0, -3])))), 720, 720, 5, 0, 2.2).panY, 0.0417);
});

test("patches moving away from the centre read as a push-in (zoom > 1); towards it as a pull-back", () => {
  const s = 0.01;
  const inward = grid((x, y) => [-Math.round(s * (x - 360)), -Math.round(s * (y - 360))]);
  const push = cameraMove(readTrf(trf(Array.from({ length: 10 }, () => inward))), 720, 720, 5, 0, 2.2);
  assert.ok(push.zoom > 1.08 && push.zoom < 1.12, `zoom ${push.zoom}`);
  assert.equal(push.panX, 0);
  assert.equal(push.panY, 0);
  const outward = grid((x, y) => [Math.round(s * (x - 360)), Math.round(s * (y - 360))]);
  assert.ok(cameraMove(readTrf(trf(Array.from({ length: 10 }, () => outward))), 720, 720, 5, 0, 2.2).zoom < 0.92);
});

test("an outlier patch (a moving object) is dropped; frames with under 4 motions count as still", () => {
  const list = grid(() => [4, 0]);
  list[12] = [-60, 40, 360, 360];
  const move = cameraMove(readTrf(trf([list])), 720, 720, 5, 0, 1);
  assert.equal(move.panX, -0.0056);
  assert.equal(move.panY, 0);
  assert.equal(move.zoom, 1);
  assert.deepEqual(cameraMove(readTrf(trf([[[9, 9, 100, 100], [9, 9, 200, 200], [9, 9, 300, 300]]])), 720, 720, 5, 0, 1), { panX: 0, panY: 0, zoom: 1, seconds: 0.2 });
});

test("stretches next to each other add up to the whole (the last step of each is counted)", () => {
  const frames = readTrf(trf(Array.from({ length: 10 }, () => grid(() => [4, 0]))));
  const a = cameraMove(frames, 720, 720, 5, 0, 1), b = cameraMove(frames, 720, 720, 5, 1, 2);
  assert.equal(+(a.panX + b.panX).toFixed(4), cameraMove(frames, 720, 720, 5, 0, 2).panX);
});

test("a stretch past the end of the file stops at its last frame", () => {
  const frames = readTrf(trf(Array.from({ length: 4 }, () => grid(() => [4, 0]))));
  assert.deepEqual(cameraMove(frames, 720, 720, 5, 0, 10), { panX: -0.0222, panY: 0, zoom: 1, seconds: 0.8 });
});

test("the real sample: pushes in over the first shot, then slides (picture left, camera right) over the detail shot", () => {
  const frames = readTrf(readFileSync(fixture, "utf8"));
  assert.equal(frames.length, 26);
  const first = cameraMove(frames, 720, 720, 5, 0, 3);
  assert.ok(first.zoom > 1.2, `zoom ${first.zoom}`);
  assert.ok(Math.abs(first.panX) < 0.03, `panX ${first.panX}`);
  const detail = cameraMove(frames, 720, 720, 5, 3, 5.2);
  assert.ok(detail.panX < -0.2, `panX ${detail.panX}`);
  assert.ok(Math.abs(detail.panY) < 0.1, `panY ${detail.panY}`);
});

test("the command line prints the same move as JSON", () => {
  const out = execFileSync(process.execPath, [motion, fixture, "720", "720", "5", "3", "5.2"], { encoding: "utf8" });
  assert.deepEqual(JSON.parse(out), cameraMove(readTrf(readFileSync(fixture, "utf8")), 720, 720, 5, 3, 5.2));
});
