// On the real printer, through the real page in a test browser: stop a long print, print again, print a note.
const port = 9334;
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
    if (dev && !picked) { picked = true; cmd("DeviceAccess.selectPrompt", { id: d.params.id, deviceId: dev.id }); }
  }
};
for (const domain of ["Page", "Runtime", "DeviceAccess"]) await cmd(`${domain}.enable`);
await cmd("Emulation.setDeviceMetricsOverride", { width: 1300, height: 900, deviceScaleFactor: 1, mobile: false });
await cmd("Page.navigate", { url: "http://localhost:8802/?theme=light" });
await sleep(1800);
const run = async (expr) => { const r = await cmd("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) errs.push("eval " + JSON.stringify(r.exceptionDetails).slice(0, 300)); return r.result?.value; };
const rectOf = async (id) => JSON.parse(await run(`JSON.stringify((() => { const b = $("${id}").getBoundingClientRect(); return { x: b.x + b.width / 2, y: b.y + b.height / 2 }; })())`));
// This run tests Bluetooth LE: the main button now opens the paired serial link when the browser has Web Serial.
let r = await rectOf(await run(`$("useble").hidden ? "print" : "useble"`));
const mouse = (type, x, y, buttons = 1) => cmd("Input.dispatchMouseEvent", { type, x, y, button: "left", buttons, clickCount: 1 });
await mouse("mousePressed", r.x, r.y); await mouse("mouseReleased", r.x, r.y, 0);
for (let i = 0; i < 250 && !(await run(`printer.connected`)); i++) await sleep(100);
if (!(await run(`printer.connected`))) { console.log("printer not free: not connected. toast:", await run(`$("toast").textContent`)); process.exit(2); }
for (let i = 0; i < 100 && (await run(`connecting`)); i++) await sleep(100);  // the Print button is disabled until then
console.log("connected:", await run(`printer.label()`));
const typed = async (text) => { await run(`state.sources.length = 0; $("font").value = "mono"; $("fontSize").value = 9; state.sources.push({ kind: "text", text: ${JSON.stringify(text)}, name: "Text" }); rerender()`); await sleep(500); };
const idle = async () => { for (let i = 0; i < 600 && (await run(`busy`)); i++) await sleep(100); };

const lines = Array.from({ length: 40 }, (_, i) => `STOP TEST line ${i + 1}`).join("\n");
await typed(lines);
console.log("long job:", await run(`$("summary").textContent`));
await run(`$("print").click()`);
await sleep(3000);
if (!(await run(`busy`))) { console.log("the long job did not start"); process.exit(3); }
const t0 = Date.now();
await run(`$("cancel").click()`);
console.log("stop pressed after 3 s, sent so far:", await run(`$("eta").textContent`), "· button:", await run(`$("cancel").lastChild.textContent`));
await idle();
console.log(`stopped in ${((Date.now() - t0) / 1000).toFixed(1)} s, toast: ${await run(`$("toast").textContent`)}`);

await typed("AFTER STOP\nThis line must be sharp\nand not shifted.");
await run(`$("print").click()`);
await sleep(300); await idle();
console.log("next job, toast:", await run(`$("toast").textContent`));

if (process.argv[2] === "nonote") { await run(`printer.disconnect()`); await sleep(800); console.log("errors:", errs.join(" | ") || "(none)"); process.exit(0); }
await run(`state.sources.length = 0; rerender()`); await sleep(300);
await run(`$("addnote").click()`); await sleep(1200);
const box = JSON.parse(await run(`(() => { const b = document.querySelector(".ink").getBoundingClientRect(); return JSON.stringify({ x: b.x, y: b.y }); })()`));
await mouse("mousePressed", box.x + 40, box.y + 60);
for (let i = 1; i <= 40; i++) await mouse("mouseMoved", box.x + 40 + i * 8, box.y + 60 + 24 * Math.sin(i / 2));
await mouse("mouseReleased", box.x + 360, box.y + 60, 0);
await sleep(600);
console.log("note:", await run(`$("summary").textContent`));
await run(`$("print").click()`);
await sleep(300); await idle();
console.log("note, toast:", await run(`$("toast").textContent`));
await run(`printer.disconnect()`); await sleep(800);
console.log("errors:", errs.join(" | ") || "(none)");
ws.close();
