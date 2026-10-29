const HELP = `Checks that focusing the native address bar doesn't move the address text.

  node apps/browser/scripts/url-focus-test.mjs <Debug Solara.app> [--keep DIR]

One hidden instance with the native omnibox. For each case (https, http and a long URL, light and dark) it
snapshots the window at rest, opens the command panel, snapshots again, then finds the resting host's ink in the
focused snapshot. The host must land within 0.5 pt of where it was, and the field's text must start with the scheme.
The pages are on a .test host, so nothing loads and nothing leaves the machine. Exits 1 on any failure.`;

import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { inflateSync } from "node:zlib";
import { launch } from "../../../scripts/lib/instance.mjs";

const argv = process.argv.slice(2);
if (!argv.length || argv.includes("-h") || argv.includes("--help")) {
  console.log(HELP);
  process.exit(argv.length ? 0 : 2);
}
const app = resolve(argv[0]);
const scratch = argv.includes("--keep") ? resolve(argv[argv.indexOf("--keep") + 1]) : mkdtempSync(join(tmpdir(), "ac-url-focus-"));

function readPng(path) {
  const buf = readFileSync(path);
  let width = 0, height = 0, channels = 4;
  const idat = [];
  for (let at = 8; at < buf.length; ) {
    const length = buf.readUInt32BE(at), type = buf.toString("ascii", at + 4, at + 8);
    if (type === "IHDR") {
      width = buf.readUInt32BE(at + 8);
      height = buf.readUInt32BE(at + 12);
      channels = { 2: 3, 6: 4 }[buf[at + 17]];
    } else if (type === "IDAT") idat.push(buf.subarray(at + 8, at + 8 + length));
    at += 12 + length;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const data = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    for (let x = 0; x < stride; x++) {
      const v = raw[y * (stride + 1) + 1 + x];
      const a = x >= channels ? data[y * stride + x - channels] : 0;
      const b = y ? data[(y - 1) * stride + x] : 0;
      const c = x >= channels && y ? data[(y - 1) * stride + x - channels] : 0;
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      const pred = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][filter];
      data[y * stride + x] = (v + pred) & 255;
    }
  }
  return { width, height, channels, data };
}

const lum = (png, x, y) => {
  const i = (y * png.width + x) * png.channels;
  return 0.2126 * png.data[i] + 0.7152 * png.data[i + 1] + 0.0722 * png.data[i + 2];
};
const grey = (png, x, y) => {
  const i = (y * png.width + x) * png.channels;
  const c = [png.data[i], png.data[i + 1], png.data[i + 2]];
  return Math.max(...c) - Math.min(...c) < 40;
};
const inked = (png, dark, x, y) =>
  x >= 0 && y >= 0 && x < png.width && y < png.height && grey(png, x, y) && (dark ? lum(png, x, y) > 110 : lum(png, x, y) < 140);

function inkBox(png, dark, [x0, y0, x1, y1]) {
  let left = Infinity, right = -1, top = Infinity, bottom = -1;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) if (inked(png, dark, x, y)) {
    left = Math.min(left, x); right = Math.max(right, x); top = Math.min(top, y); bottom = Math.max(bottom, y);
  }
  return right < 0 ? null : { left, right, top, bottom };
}

function locate(rest, focused, box, dark) {
  let best = { miss: Infinity, dx: 0, dy: 0 };
  for (let dy = -8; dy <= 8; dy++)
    for (let dx = -240; dx <= 240; dx++) {
      let miss = 0;
      for (let y = box.top; y <= box.bottom && miss < best.miss; y++)
        for (let x = box.left; x <= box.right; x++) if (inked(rest, dark, x, y) !== inked(focused, dark, x + dx, y + dy)) miss++;
      if (miss < best.miss) best = { miss, dx, dy };
    }
  return best;
}

const long = `https://url-focus.test/${"segment/".repeat(14)}end?query=${"x".repeat(40)}`;
const cases = [
  { name: "https, light", url: "https://url-focus.test/dashboard", appearance: "light", scheme: "https://" },
  { name: "https, dark", url: "https://url-focus.test/dashboard", appearance: "dark", scheme: "https://" },
  { name: "http, light", url: "http://url-focus.test/a/b", appearance: "light", scheme: "http://" },
  { name: "long URL, light", url: long, appearance: "light", scheme: "https://" },
  { name: "long URL, dark", url: long, appearance: "dark", scheme: "https://" },
];

const instance = await launch(app, { data: join(scratch, "data"), fresh: true, onboarded: true });
const inApp = (body) => instance.eval(body, { timeout: 30000 });
let failed = 0;
try {
  const w = await inApp(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0]; s.setWindowFrame(w, [80, 80, 1280, 800]); return w;`);
  for (const [i, c] of cases.entries()) {
    const shots = [join(scratch, `${i}-rest.png`), join(scratch, `${i}-focused.png`)];
    const r = await inApp(`
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const s = ac.store.getState(), w = ${JSON.stringify(w)};
      s.closePanel(w);
      s.updateSettings({ appearance: ${JSON.stringify(c.appearance)}, showFullUrl: false });
      s.newTab(w, { url: ${JSON.stringify(c.url)} });
      return sleep(2500)
        .then(() => ac.shell.devSnapshotWindow(w, ${JSON.stringify(shots[0])}))
        .then(() => s.openPanel(w, ${JSON.stringify(c.url)}))
        .then(() => sleep(900))
        .then(() => ac.shell.devSnapshotWindow(w, ${JSON.stringify(shots[1])}))
        .then(() => ({ value: String(ac.omnibox.get(w + ":panel")?.state().value ?? ""), frame: ac.store.getState().windows[w].frame }));`);
    const rest = readPng(shots[0]), focused = readPng(shots[1]);
    const scale = Math.round(rest.width / r.frame[2]);
    const dark = c.appearance === "dark";
    const box = inkBox(rest, dark, [Math.round(330 * scale), Math.round(14 * scale), Math.round(rest.width - 160 * scale), Math.round(30 * scale)]);
    const found = box && locate(rest, focused, box, dark);
    const dx = found ? found.dx / scale : NaN, dy = found ? found.dy / scale : NaN;
    const ok = !!found && Math.abs(dx) <= 0.5 && Math.abs(dy) <= 0.5 && r.value.startsWith(c.scheme);
    if (!ok) failed++;
    console.log(`${ok ? "PASS" : "FAIL"} ${c.name}: host moved ${dx} pt, ${dy} pt; field starts "${r.value.slice(0, 12)}"`);
  }
} finally {
  await instance.quit();
}
console.log(failed ? `${failed} of ${cases.length} failed (snapshots in ${scratch})` : `all ${cases.length} pass`);
process.exit(failed ? 1 : 0);
