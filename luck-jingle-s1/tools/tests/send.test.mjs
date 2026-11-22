// Runs the page's own protocol code against a simulated printer. No hardware.
import { readFileSync } from "node:fs";
const html = readFileSync(new URL("../../web/index.html", import.meta.url), "utf8");
const a = html.indexOf("const HEAD = 384"), b = html.indexOf("// Rendering");
let code = html.slice(a, html.lastIndexOf("// ---", b));
code = code.replace("CREDIT_TIMEOUT = 15000", "CREDIT_TIMEOUT = 700").replace("OK_TIMEOUT = 20000", "OK_TIMEOUT = 700").replace("STOP_WAIT = 3500", "STOP_WAIT = 80");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const { S1Printer, buildJob, HEAD, BPL, DPMM } = new Function("sleep", "navigator", code + "\nreturn { S1Printer, buildJob, HEAD, BPL, DPMM };")(sleep, globalThis.__nav = { bluetooth: {} });

function rig({ creditPerWrite = 1, okAfter = 5, rejectAbove = 0, stallAfter = Infinity, ok = true, initial = 5 } = {}) {
  const p = new S1Printer();
  const rx = [], stamps = [], sizes = []; let writes = 0, overrun = 0, timer;
  p.device = { gatt: { connected: true, disconnect() {} } };
  p.credits = initial;
  p.tx = { async writeValueWithoutResponse(chunk) {
    if (rejectAbove && chunk.length > rejectAbove) throw new Error("too long");
    if (p.credits < 0) overrun++;
    rx.push(...chunk); writes++; stamps.push(Date.now()); sizes.push(chunk.length);
    if (writes < stallAfter) setTimeout(() => { p.credits += creditPerWrite; p.wake?.(); }, 0);
    clearTimeout(timer);
    if (ok) timer = setTimeout(() => p.onReply?.(new Uint8Array([0x4f, 0x4b])), okAfter);
  } };
  return { p, rx, stamps, sizes, stats: () => ({ writes, overrun }) };
}
// Parses the byte stream the way the printer would.
function parse(bytes) {
  const out = []; let i = 0;
  while (i < bytes.length) {
    if (bytes[i] === 0x1d && bytes[i + 1] === 0x76) {
      const w = bytes[i + 4] | (bytes[i + 5] << 8), h = bytes[i + 6] | (bytes[i + 7] << 8);
      out.push({ raster: h, w, rows: bytes.slice(i + 8, i + 8 + w * h) }); i += 8 + w * h;
    } else if (bytes[i] === 0x1b && bytes[i + 1] === 0x4a) { out.push({ feed: bytes[i + 2] }); i += 3; }
    else throw new Error(`bad byte ${bytes[i]} at ${i}`);
  }
  return out;
}
const page = (rows, v = 0xaa) => new Uint8Array(rows * BPL).fill(v);
// The pause before the write that starts at byte `at`: the final feed is many writes, so the last two say nothing.
const gapAt = (stamps, sizes, at) => { for (let k = 0, off = 0; k < sizes.length; off += sizes[k++]) if (off === at) return stamps[k] - stamps[k - 1]; return NaN; };
let failed = 0;
const check = (name, cond, extra = "") => { console.log(`${cond ? "ok  " : "FAIL"} ${name} ${extra}`); if (!cond) failed++; };

{ // 640 rows, 15 mm tail
  const { p, rx, stats } = rig();
  const r = await p.send(buildJob([page(640)], 15), null, null);
  const parsed = parse(rx);
  check("normal: one raster command for the page", parsed.filter((x) => x.raster).map((x) => x.raster).join() === "640,120");
  check("normal: all rows intact", parsed.filter((x) => x.raster === 640).every((x) => x.rows.every((b) => b === 0xaa)));
  check("normal: tail is 120 blank rows", parsed.at(-1).raster === 120 && parsed.at(-1).rows.every((b) => b === 0));
  check("normal: no overrun and confirmed", stats().overrun === 0 && r.finished && r.confirmed);
}
{ // Long tail: one blank raster of 320 rows
  const { p, rx } = rig();
  await p.send(buildJob([page(10)], 40), null, null);
  check("long tail is one blank raster", parse(rx).map((x) => x.raster ?? `f${x.feed}`).join() === "10,320");
}
{ // Two pages
  const { p, rx } = rig();
  await p.send(buildJob([page(10), page(20)], 0), null, null);
  check("two pages with a 3 mm gap", parse(rx).map((x) => x.raster ?? `f${x.feed}`).join() === "10,f24,20");
}
{ // Stop in the middle of a page
  const { p, rx, stamps, sizes } = rig(); const ctl = new AbortController();
  const r = await p.send(buildJob([page(640)], 15), (done) => { if (done > 3000) ctl.abort(); }, ctl.signal);
  const tail = 8 + BPL * 120;
  const body = rx.length - tail - 8, feedOut = parse(rx.slice(rx.length - tail)), wait = gapAt(stamps, sizes, rx.length - tail);
  check("stop: sending ends at once, on a whole row", body < 3400 && body % BPL === 0, `${body / BPL} of 640 rows sent`);
  check("stop: the paper still feeds out", feedOut.length === 1 && feedOut[0].raster === 120 && feedOut[0].rows.every((b) => b === 0) && r.finished === false);
  check("stop: the feed waits for the printer to drop the raster", wait >= 75, `${wait} ms`);
}
// A page like text: 20 rows of ink, then 6 blank, over and over.
const textPage = (rows) => { const out = new Uint8Array(rows * BPL); for (let y = 0; y < rows; y++) if (y % 26 < 20) out.fill(0xaa, y * BPL, (y + 1) * BPL); return { bits: out, rows }; };
{ // Stop inside a line of text finishes that line
  const { p, rx } = rig(); const ctl = new AbortController();
  const stopAt = 8 + 26 * 5 * BPL + 5 * BPL;  // the sixth line, 5 rows in
  await p.send(buildJob([textPage(640).bits], 0), (done) => { if (done >= stopAt) ctl.abort(); }, ctl.signal);
  const rows = (rx.length - 8) / BPL, lastRow = rx.slice(-BPL), before = rx.slice(-2 * BPL, -BPL);
  check("stop: a line of text is not cut", Number.isInteger(rows) && lastRow.every((b) => b === 0) && before.some((b) => b !== 0), `${rows} rows sent`);
  check("stop: and ends on the first blank row after it", rows % 26 === 21 && rows < 26 * 8, `${rows} rows sent`);
}
{ // Stop near the end of a picture lets the page end, with no wait for the printer to drop it
  const { p, rx, stamps, sizes } = rig(); const ctl = new AbortController();
  const job = buildJob([page(100)], 5);
  await p.send(job, (done) => { if (done >= job[0].bytes.length - 30 * BPL) ctl.abort(); }, ctl.signal);
  const wait = gapAt(stamps, sizes, job[0].bytes.length);
  check("stop near the end of a page: the page is whole", rx.length === job[0].bytes.length + job[1].bytes.length && parse(rx).map((x) => x.raster).join() === "100,40", `${rx.length} bytes`);
  check("stop near the end of a page: no wait", wait < 60, `${wait} ms`);
}
{ // Stop also drops the pages that were still to come
  const { p, rx } = rig(); const ctl = new AbortController();
  await p.send(buildJob([page(300), page(300)], 5), (done) => { if (done > 3000) ctl.abort(); }, ctl.signal);
  let headers = 0; for (let i = 0; i + 1 < rx.length; i++) if (rx[i] === 0x1d && rx[i + 1] === 0x76) headers++;
  check("stop: later pages never start (the cut page and the blank feed only)", headers === 2 && rx.length - (8 + BPL * 40) < 3400, `${rx.length} bytes`);
}
{ // Stop between pages leaves no raster open, so no wait
  const { p, rx } = rig(); const ctl = new AbortController();
  const job = buildJob([page(10), page(10)], 5);
  await p.send(job, (done) => { if (done === job[0].bytes.length) ctl.abort(); }, ctl.signal);
  check("stop between pages: only the first page and the feed", rx.length === job[0].bytes.length + job.at(-1).bytes.length && parse(rx).map((x) => x.raster).join() === "10,40", `${rx.length} bytes`);
}
{ // A link that rejects big packets
  const { p, rx } = rig({ rejectAbove: 60 });
  await p.send(buildJob([page(100)], 2), null, null);
  check("shrinks packets, data intact", p.packet === 50 && parse(rx)[0].rows.every((b) => b === 0xaa), `packet ${p.packet}`);
}
{ // Printer stops giving credits, as a paper-out printer might
  const { p, rx } = rig({ stallAfter: 3 });
  let err = null;
  await p.send(buildJob([page(300)], 0), null, null).catch((e) => (err = e));
  check("stall: error, no fake credit", /stopped accepting/.test(err?.message) && rx.length <= 8 * 200, `sent ${rx.length} bytes`);
}
{ // No OK at all
  const { p } = rig({ ok: false });
  const r = await p.send(buildJob([page(10)], 0), null, null);
  check("no OK: reported as unconfirmed", r.finished && !r.confirmed);
}
{ // Disconnect during the job
  const { p } = rig({ stallAfter: 2 });
  setTimeout(() => { p.device.gatt.connected = false; p.wake?.(); }, 50);
  let err = null;
  await p.send(buildJob([page(300)], 0), null, null).catch((e) => (err = e));
  check("disconnect: clear error", /disconnected/.test(err?.message));
}
{ // Connecting while the printer gives no credits (seen with the USB cable plugged in)
  const nav = globalThis.__nav;
  const char = () => ({ addEventListener() {}, startNotifications: async () => {} });
  let closed = false;
  const device = { name: "PPS1_4367_BLE", addEventListener() {}, gatt: { connected: true, disconnect() { closed = true; this.connected = false; }, connect: async () => ({ getPrimaryService: async () => ({ getCharacteristic: async () => char() }) }) } };
  nav.bluetooth.requestDevice = async (o) => { nav.seen = o; return device; };
  const p = new S1Printer(); let err = null;
  await p.connect().catch((e) => (err = e));
  check("connect: filters by name prefix", nav.seen.filters.map((f) => f.namePrefix).join() === "PPS1,S1_" && nav.seen.optionalServices[0] === 0xff00);
  check("connect: no credits gives the USB hint, and closes", /USB cable/.test(err?.message) && closed);
}
console.log(failed ? `${failed} FAILED` : "all passed");
process.exit(failed ? 1 : 0);
