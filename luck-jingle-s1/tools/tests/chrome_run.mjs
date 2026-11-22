// Prints the demo lab result from the real page in a test browser and records every write and notification.
import { writeFileSync } from "node:fs";
const outDir = process.argv[2], port = 9334;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let targets;
for (let i = 0; i < 40 && !targets; i++) { try { targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); } catch { await sleep(250); } }
const ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0, picked = false; const wait = new Map(), errs = [];
const cmd = (method, params = {}) => new Promise((r) => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
ws.onmessage = (m) => {
  const d = JSON.parse(m.data);
  if (d.id) { wait.get(d.id)?.(d.result ?? d); wait.delete(d.id); return; }
  if (d.method === "Runtime.exceptionThrown") errs.push(JSON.stringify(d.params.exceptionDetails).slice(0, 240));
  if (d.method === "DeviceAccess.deviceRequestPrompted") {
    const dev = d.params.devices.find((x) => x.name.startsWith("PPS1"));
    console.log("prompt:", d.params.devices.map((x) => x.name).join(", ") || "(no devices yet)");
    if (dev && !picked) { picked = true; cmd("DeviceAccess.selectPrompt", { id: d.params.id, deviceId: dev.id }); }
  }
};
for (const domain of ["Page", "Runtime", "DeviceAccess"]) await cmd(`${domain}.enable`);
await cmd("Emulation.setDeviceMetricsOverride", { width: 1300, height: 900, deviceScaleFactor: 1, mobile: false });
await cmd("Page.navigate", { url: "http://localhost:8802/?theme=light" });
await sleep(1800);
const run = async (expr) => { const r = await cmd("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) errs.push("eval " + JSON.stringify(r.exceptionDetails).slice(0, 300)); return r.result?.value; };
await run(`(() => {
  window.__log = [];
  const P = BluetoothRemoteGATTCharacteristic.prototype, add = P.addEventListener, w = P.writeValueWithoutResponse;
  P.addEventListener = function (type, fn, ...rest) { const u = this.uuid.slice(4, 8); return add.call(this, type, (e) => { const v = e.target.value; __log.push(["rx", performance.now(), u, [...new Uint8Array(v.buffer, v.byteOffset, v.byteLength)]]); fn(e); }, ...rest); };
  P.writeValueWithoutResponse = function (d) { const t = performance.now(); return w.call(this, d).then((r) => { __log.push(["tx", t, performance.now(), d.byteLength]); return r; }); };
})()`);
const rectOf = async (id) => JSON.parse(await run(`JSON.stringify((() => { const b = $("${id}").getBoundingClientRect(); return { x: b.x + b.width / 2, y: b.y + b.height / 2 }; })())`));
// This run tests Bluetooth LE: the main button now opens the paired serial link when the browser has Web Serial.
let r = await rectOf(await run(`$("useble").hidden ? "print" : "useble"`));
const click = async () => { for (const type of ["mousePressed", "mouseReleased"]) await cmd("Input.dispatchMouseEvent", { type, x: r.x, y: r.y, button: "left", buttons: 1, clickCount: 1 }); };
await click();
for (let i = 0; i < 300 && !(await run(`printer.connected`)); i++) await sleep(100);
if (!(await run(`printer.connected`))) { console.log("not connected. toast:", await run(`$("toast").textContent`), "errors:", errs.join(" | ")); process.exit(2); }
console.log("connected:", await run(`printer.label()`), "packet", await run(`printer.packet`));
console.log("idle 15 s, as when a person connects first and prints later");
await sleep(15000);
await run(`$("demo").click()`); await sleep(600);
await run(`state.sources[0].text = state.sources[0].text.replace("DEMO LAB RESULT", "CHROME RUN"); rerender()`); await sleep(600);
await run(`__log.length = 0; window.__start = performance.now()`);
r = await rectOf("print");
await click();
await sleep(500);
for (let i = 0; i < 600 && (await run(`busy`)); i++) await sleep(100);
console.log("toast:", await run(`$("toast").textContent`));
const log = JSON.parse(await run(`JSON.stringify(__log)`)), start = await run(`__start`);
const tx = log.filter((e) => e[0] === "tx"); let sent = 0; const rows = [];
tx.forEach((e, i) => { rows.push({ t: e[1] - start, gap: i ? e[1] - tx[i - 1][1] : 0, at: sent, resolve: e[2] - e[1] }); sent += e[3]; });
console.log(`${sent} bytes in ${tx.length} writes over ${((tx.at(-1)[1] - tx[0][1]) / 1000).toFixed(2)} s`);
console.log("longest waits between writes:");
for (const x of [...rows].sort((a, b) => b.gap - a.gap).slice(0, 8)) console.log(`  ${x.gap.toFixed(0).padStart(5)} ms before byte ${x.at} (row ${Math.floor((x.at - 8) / 48)}), at ${(x.t / 1000).toFixed(2)} s`);
console.log("longest write calls:", [...rows].sort((a, b) => b.resolve - a.resolve).slice(0, 3).map((x) => x.resolve.toFixed(0) + " ms").join(", "));
const flow = log.filter((e) => e[0] === "rx" && e[2] === "ff03"), replies = log.filter((e) => e[0] === "rx" && e[2] === "ff01");
const fgaps = flow.map((e, i) => (i ? e[1] - flow[i - 1][1] : 0)).sort((a, b) => b - a).slice(0, 4).map((x) => x.toFixed(0) + " ms");
console.log(`credit notifications: ${flow.length}, longest waits ${fgaps.join(", ")}`);
console.log("replies:", replies.map((e) => `${((e[1] - start) / 1000).toFixed(2)} s ${e[3].map((b) => b.toString(16).padStart(2, "0")).join(" ")}`).join(" | ") || "(none)");
writeFileSync(`${outDir}/chrome_log.json`, JSON.stringify(rows));
const b64 = await run(`(() => { state.sources[0].text = state.sources[0].text.replace("CHROME RUN", "PYTHON RUN"); return rerender().then(() => { const parts = buildJob(printable().map((p) => p.bits), opts().tail).map((p) => p.bytes); const n = parts.reduce((s, p) => s + p.length, 0), all = new Uint8Array(n); let o = 0; for (const p of parts) { all.set(p, o); o += p.length; } let s = ""; for (let i = 0; i < n; i += 8192) s += String.fromCharCode(...all.subarray(i, i + 8192)); return btoa(s); }); })()`);
writeFileSync(`${outDir}/python_job.bin`, Buffer.from(b64, "base64"));
console.log("control job bytes:", Buffer.from(b64, "base64").length);
await run(`printer.disconnect()`); await sleep(800);
console.log("errors:", errs.join(" | ") || "(none)");
ws.close();
