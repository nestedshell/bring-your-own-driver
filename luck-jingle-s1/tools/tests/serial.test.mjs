// Runs the page's paired-link (Web Serial) code against a fake serial port. No hardware.
import { readFileSync } from "node:fs";
const html = readFileSync(new URL("../../web/index.html", import.meta.url), "utf8");
const a = html.indexOf("const HEAD = 384"), b = html.indexOf("// Rendering");
let code = html.slice(a, html.lastIndexOf("// ---", b));
code = code.replace("STOP_WAIT = 3500", "STOP_WAIT = 80").replace("SERIAL_OK_WAIT = 3000", "SERIAL_OK_WAIT = 300")
  .replace("SERIAL_ANSWER = 3000", "SERIAL_ANSWER = 200")
  .replace("WRITE_TIMEOUT = 15000", "WRITE_TIMEOUT = 300");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nav = {};
const { S1Serial, buildJob, BPL, SPP, SERIAL_CHUNK } = new Function("sleep", "navigator", code + "\nreturn { S1Serial, buildJob, BPL, SPP, SERIAL_CHUNK };")(sleep, nav);

// A connected link whose writer records every chunk. `gate` holds the writer's `ready` until released.
function rig({ ok = false, okAfter = 5, stallAfter = Infinity, failAfter = Infinity, gate = false } = {}) {
  const p = new S1Serial();
  const chunks = [], stamps = []; let writes = 0, early = 0, release = null, timer, aborted = false;
  let ready = gate ? new Promise((r) => (release = r)) : Promise.resolve();
  p.open = true; p.port = {};
  p.writer = {
    get ready() { return ready; },
    write(chunk) {
      if (gate && !release.done) early++;
      writes++;
      if (writes > failAfter) { p.open = false; return Promise.reject(new Error("NetworkError")); }  // the link went away
      if (writes > stallAfter) return new Promise(() => {});
      chunks.push(Uint8Array.from(chunk)); stamps.push(Date.now());
      clearTimeout(timer);
      if (ok) timer = setTimeout(() => p.onReply?.(new Uint8Array([0x4f, 0x4b])), okAfter);
      return Promise.resolve();
    },
    async abort() { aborted = true; },
    releaseLock() {},
  };
  const open = () => { release.done = true; release(); };
  return { p, chunks, stamps, rx: () => chunks.flatMap((c) => [...c]), open, aborted: () => aborted };
}
function parse(bytes) {
  const out = []; let i = 0;
  while (i < bytes.length) {
    if (bytes[i] === 0x1d && bytes[i + 1] === 0x76) {
      const w = bytes[i + 4] | (bytes[i + 5] << 8), h = bytes[i + 6] | (bytes[i + 7] << 8);
      out.push({ raster: h, rows: bytes.slice(i + 8, i + 8 + w * h) }); i += 8 + w * h;
    } else if (bytes[i] === 0x1b && bytes[i + 1] === 0x4a) { out.push({ feed: bytes[i + 2] }); i += 3; }
    else throw new Error(`bad byte ${bytes[i]} at ${i}`);
  }
  return out;
}
const page = (rows, v = 0xaa) => new Uint8Array(rows * BPL).fill(v);
let failed = 0;
const check = (name, cond, extra = "") => { console.log(`${cond ? "ok  " : "FAIL"} ${name} ${extra}`); if (!cond) failed++; };

{ // The whole job, in order, in chunks no larger than the chunk size
  const { p, chunks, rx } = rig();
  const job = buildJob([page(300), page(20, 0x55)], 15);
  const r = await p.send(job, null, null);
  const expected = job.flatMap((x) => [...x.bytes]);
  check("serial: every byte in order", rx().length === expected.length && rx().every((v, i) => v === expected[i]), `${rx().length} bytes`);
  check("serial: chunks of at most the chunk size", chunks.every((c) => c.length <= SERIAL_CHUNK) && chunks.length > 1, `${chunks.length} chunks`);
  check("serial: two pages, gap and tail", parse(rx()).map((x) => x.raster ?? `f${x.feed}`).join() === "300,f24,20,120");
  check("serial: no OK means printed but unconfirmed", r.finished && !r.confirmed);
}
{ // An OK, if the printer sends one, confirms the job
  const { p } = rig({ ok: true });
  const r = await p.send(buildJob([page(50)], 5), null, null);
  check("serial: an OK confirms", r.finished && r.confirmed);
}
{ // An OK split across two reads still counts
  const { p } = rig();
  setTimeout(() => { p.onReply?.(new Uint8Array([0x4f])); p.onReply?.(new Uint8Array([0x4b])); }, 30);
  const r = await p.send(buildJob([page(10)], 0), null, null);
  check("serial: an OK split across reads confirms", r.confirmed);
}
{ // Backpressure: nothing is written before the port is ready for it
  const { p, chunks, open } = rig({ gate: true });
  const sending = p.send(buildJob([page(10)], 0), null, null);
  await sleep(50);
  const before = chunks.length;
  open();
  await sending;
  check("serial: waits for the port to be ready", before === 0 && chunks.length > 0, `${before} written before ready`);
}
{ // Stop in the middle of a page: the page is finished, then only the feed
  const { p, rx } = rig(); const ctl = new AbortController();
  const r = await p.send(buildJob([page(640)], 15), (done) => { if (done > 3000) ctl.abort(); }, ctl.signal);
  const bytes = rx(), body = bytes.length - (8 + BPL * 120);
  check("serial stop: the current page is finished, never cut", body === 8 + 640 * BPL, `${body} bytes before the feed`);
  check("serial stop: the paper still feeds out", parse(bytes).at(-1).raster === 120 && r.finished === false && r.confirmed === false);
}
{ // Stop also drops the pages still to come
  const { p, rx } = rig(); const ctl = new AbortController();
  await p.send(buildJob([page(300), page(300)], 5), (done) => { if (done > 3000) ctl.abort(); }, ctl.signal);
  const bytes = rx(); let headers = 0;
  for (let i = 0; i + 1 < bytes.length; i++) if (bytes[i] === 0x1d && bytes[i + 1] === 0x76) headers++;
  check("serial stop: later pages never start (the page and the blank feed only)", headers === 2, `${bytes.length} bytes`);
}
{ // Stop before anything was sent: only the final feed goes out
  const { p, rx } = rig(); const ctl = new AbortController(); ctl.abort();
  const r = await p.send(buildJob([page(100)], 5), null, ctl.signal);
  check("serial stop before start: only the feed", parse(rx()).map((x) => x.raster).join() === "40" && !r.finished);
}
{ // The port stops taking data, as a printer out of paper might
  const { p, rx, aborted } = rig({ stallAfter: 3 });
  let err = null;
  await p.send(buildJob([page(300)], 0), null, null).catch((e) => (err = e));
  check("serial stall: an error, not a hang", /stopped accepting/.test(err?.message) && rx().length === 3 * SERIAL_CHUNK, `sent ${rx().length} bytes`);
  check("serial stall: the waiting data is dropped and the link closed", aborted() && !p.connected);
}
{ // The link goes away after the last write, while the page may still be on its way
  const { p } = rig();
  setTimeout(() => p.lost(), 100);
  let err = null;
  await p.send(buildJob([page(10)], 0), null, null).catch((e) => (err = e));
  check("serial lost after the last write: a failure, not 'sent'", /disconnected/.test(err?.message), err?.message);
}
{ // The link goes away during the job
  const { p } = rig({ failAfter: 2 });
  let err = null;
  await p.send(buildJob([page(300)], 0), null, null).catch((e) => (err = e));
  check("serial disconnect: clear error", /disconnected/.test(err?.message), err?.message);
}
{ // Connecting: the browser's list, filtered to the serial service; the battery answer is the sign of life
  const opened = [], written = [];
  let closed = false, cancelled = false, feedReply = null;
  const port = {
    async open(o) { opened.push(o); },
    async close() { closed = true; },
    readable: { getReader: () => ({ read: () => new Promise((r) => (feedReply = r)), cancel: async () => { cancelled = true; feedReply?.({ done: true }); }, releaseLock() {} }) },
    writable: { getWriter: () => ({ ready: Promise.resolve(), write: async (c) => { written.push([...c]); setTimeout(() => feedReply?.({ value: new Uint8Array([0x00, 0x4d]), done: false }), 5); }, abort: async () => {}, releaseLock() {} }) },
  };
  nav.serial = { getPorts: async () => [], requestPort: async (o) => { nav.seen = o; return port; }, addEventListener() {} };
  const p = new S1Serial();
  await p.connect();
  check("serial connect: asks for the serial port service", nav.seen.filters[0].bluetoothServiceClassId === SPP && nav.seen.allowedBluetoothServiceClassIds[0] === SPP);
  check("serial connect: opens the port", opened.length === 1 && opened[0].baudRate > 0);
  check("serial connect: one read-only battery query, answered", written.length === 1 && written[0].join() === "16,255,80,241" && p.battery === 0x4d && p.connected);
  check("serial connect: the link says it is the encrypted one", /encrypted/.test(p.linkLabel) && !/not/.test(p.linkLabel));
  await p.connect({ pick: true, any: true }).catch(() => {});
  check("serial connect: 'another port' lists every port", !nav.seen.filters);
  await p.disconnect();
  check("serial disconnect: reader cancelled and port closed", cancelled && closed && !p.connected);
}
{ // A port that opens but gets no answer is closed again, with a hint
  let closed = false;
  const port = {
    async open() {}, async close() { closed = true; },
    readable: { getReader: () => { let r; return { read: () => new Promise((x) => (r = x)), cancel: async () => r?.({ done: true }), releaseLock() {} }; } },
    writable: { getWriter: () => ({ ready: Promise.resolve(), write: async () => {}, abort: async () => {}, releaseLock() {} }) },
  };
  nav.serial = { getPorts: async () => [port], requestPort: async () => { throw new Error("should use the known port"); }, addEventListener() {} };
  const p = new S1Serial(); let err = null;
  await p.connect().catch((e) => (err = e));
  check("serial connect: a port allowed before is used again", !/known port/.test(err?.message ?? ""));
  check("serial connect: no answer gives a hint, and closes", /does not answer/.test(err?.message) && closed && !p.connected);
}
{ // The link is lost (printer switched off): the port is closed, so Connect works again without a reload
  let state = "closed", endRead = null;
  const port = {
    async open() { if (state !== "closed") throw new Error("InvalidStateError: The port is already open."); state = "opened"; },
    async close() { state = "closed"; },
    readable: { getReader: () => ({ read: () => new Promise((r) => (endRead = r)), cancel: async () => endRead?.({ done: true }), releaseLock() {} }) },
    writable: { getWriter: () => ({ ready: Promise.resolve(), write: async () => { setTimeout(() => endRead?.({ value: new Uint8Array([0x00, 0x40]), done: false }), 5); }, abort: async () => {}, releaseLock() {} }) },
  };
  nav.serial = { getPorts: async () => [port], requestPort: async () => port, addEventListener() {} };
  const p = new S1Serial(); let lost = 0;
  p.ondisconnect = () => lost++;
  await p.connect();
  endRead({ done: true });  // the stream ends, as when the printer goes away
  await sleep(50);
  check("serial lost: the page is told, and the port is closed", lost === 1 && !p.connected && state === "closed");
  let err = null;
  await p.connect().catch((e) => (err = e));
  check("serial lost: Connect works again", !err && p.connected, err?.message);
  await p.disconnect();
}
{ // A port the browser reports as USB is not called the encrypted Bluetooth link
  let endRead = null;
  const port = {
    getInfo: () => ({ usbVendorId: 0x1a86, usbProductId: 0x7523 }),
    async open() {}, async close() {},
    readable: { getReader: () => ({ read: () => new Promise((r) => (endRead = r)), cancel: async () => endRead?.({ done: true }), releaseLock() {} }) },
    writable: { getWriter: () => ({ ready: Promise.resolve(), write: async () => { setTimeout(() => endRead?.({ value: new Uint8Array([0x00, 0x40]), done: false }), 5); }, abort: async () => {}, releaseLock() {} }) },
  };
  nav.serial = { getPorts: async () => [port], requestPort: async () => port, addEventListener() {} };
  const p = new S1Serial();
  await p.connect();
  check("serial connect: a USB port is not labelled encrypted", p.connected && !/encrypted\)/.test(p.linkLabel) && !p.encrypted, p.linkLabel);
  await p.disconnect();
}
{ // Chrome on a Mac: the first open of a Bluetooth port ends without the printer, the second one works (note 63)
  let opens = 0, asked = 0, endRead = null, down = false;
  const port = {
    getInfo: () => ({ bluetoothServiceClassId: SPP }),
    async open() { if (++opens === 1 || down) throw new Error("Failed to open serial port."); }, async close() {},
    readable: { getReader: () => ({ read: () => new Promise((r) => (endRead = r)), cancel: async () => endRead?.({ done: true }), releaseLock() {} }) },
    writable: { getWriter: () => ({ ready: Promise.resolve(), write: async () => { setTimeout(() => endRead?.({ value: new Uint8Array([0x00, 0x40]), done: false }), 5); }, abort: async () => {}, releaseLock() {} }) },
  };
  nav.serial = { getPorts: async () => [port], requestPort: async () => { asked++; return port; }, addEventListener() {} };
  nav.userAgentData = { platform: "macOS" };
  const p = new S1Serial();
  await p.connect();
  check("serial connect on a Mac: a failed first open is tried once more", opens === 2 && p.connected && asked === 0, `${opens} opens`);
  await p.disconnect();
  opens = 0; down = true;
  let stuck = null;
  await p.connect().catch((e) => (stuck = e));
  check("serial connect on a Mac: two failed opens say what to do", opens === 2 && /quit Chrome/.test(stuck?.message) && !p.connected, `${opens} opens`);
  nav.userAgentData = { platform: "Linux" };
  opens = 0; down = false;
  const q = new S1Serial(); let err = null;
  await q.connect().catch((e) => (err = e));
  check("serial connect elsewhere: a failed open is reported, not repeated", opens === 1 && /Failed to open/.test(err?.message) && !q.connected, `${opens} opens`);
  await q.connect();
  check("serial connect: after a failure the list is shown again", asked === 1 && q.connected, `asked ${asked}`);
  await q.disconnect();
  await q.connect();
  check("serial connect: after a success the allowed port is used without the list", asked === 1 && q.connected, `asked ${asked}`);
  await q.disconnect();
  delete nav.userAgentData;
}
console.log(failed ? `${failed} FAILED` : "all passed");
process.exit(failed ? 1 : 0);
