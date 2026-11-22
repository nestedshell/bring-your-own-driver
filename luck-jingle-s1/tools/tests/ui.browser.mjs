// Exercises the real page in a browser with no printer: add, type, remove, and check the layout.
import { readFileSync, writeFileSync } from "node:fs";
const outDir = process.argv[2], port = 9333;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let targets;
for (let i = 0; i < 40 && !targets; i++) { try { targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); } catch { await sleep(250); } }
const ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0; const wait = new Map(), log = [], net = [];
ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id) { wait.get(d.id)?.(d.result ?? d); wait.delete(d.id); }
  else if (d.method === "Runtime.exceptionThrown") log.push("exception " + JSON.stringify(d.params.exceptionDetails.exception?.description ?? d.params.exceptionDetails.text).slice(0, 240));
  else if (d.method === "Log.entryAdded" && d.params.entry.level === "error") log.push(d.params.entry.text.slice(0, 200));
  else if (d.method === "Network.requestWillBeSent" && !/^(data|blob):/.test(d.params.request.url)) net.push(d.params.request.url.slice(0, 80)); };
const cmd = (method, params = {}) => new Promise((r) => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
for (const domain of ["Page", "Runtime", "Log", "Network"]) await cmd(`${domain}.enable`);
const run = async (expr) => { const r = await cmd("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) log.push("eval: " + JSON.stringify(r.exceptionDetails).slice(0, 240)); return r.result?.value; };
const shot = async (name) => writeFileSync(`${outDir}/ui_${name}.png`, Buffer.from((await cmd("Page.captureScreenshot", { format: "png" })).data, "base64"));
let failed = 0;
const check = (name, ok, extra = "") => { console.log(`${ok ? "ok  " : "FAIL"} ${name} ${extra}`); if (!ok) failed++; };
const size = (w, h) => cmd("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: false });
const fits = `(() => { const a = document.querySelector("aside").getBoundingClientRect(); return [...document.querySelectorAll(".group, .row, .switch, .copies")].filter(n => n.getBoundingClientRect().right > a.right + .5).length + (document.querySelector(".scroll").scrollWidth - document.querySelector(".scroll").clientWidth); })()`;
const images = `(async () => { const names = ["Screenshot 2026-10-31 at 19.17.53 with quite a long name to test.png", "a.png"], sizes = [[900, 500], [500, 900]], files = [];
  for (let i = 0; i < 2; i++) { const c = new OffscreenCanvas(...sizes[i]), x = c.getContext("2d"); x.fillStyle = "#777"; x.fillRect(0, 0, ...sizes[i]); x.fillStyle = "#000"; x.font = "70px Helvetica"; x.fillText("Image " + (i + 1), 30, 140); files.push(new File([await c.convertToBlob()], names[i], { type: "image/png" })); }
  await addFiles(files); })()`;

await size(1300, 900);
await cmd("Page.navigate", { url: "http://localhost:8802/?calibration&theme=dark" });
await sleep(2000);
check("old URL adds nothing on load", await run(`state.sources.length`) === 0);
check("tile is the big empty state", await run(`$("tile").classList.contains("only")`));
check("button offers the paired link first, enabled", await run(`$("printLabel").textContent === (navigator.serial ? "Connect (paired, encrypted)" : "Connect printer") && !$("print").disabled`));
check("the other ways to connect are offered", await run(`!$("linkopts").hidden && $("anyport").hidden === !navigator.serial`));
check("text card hidden with no text", await run(`$("textcard").hidden`));
await shot("empty");

await run(`$("demo").click()`); await sleep(600);
check("demo shows one sheet and the text card", await run(`state.pages.length === 1 && !$("textcard").hidden && $("text").value.startsWith("DEMO")`));
const u = await run(`state.pages[0].preview.toDataURL("image/png")`);
writeFileSync(`${outDir}/ui_demo_preview.png`, Buffer.from(u.split(",")[1], "base64"));
const pad = await run(`(() => { const c = state.pages[0].preview, d = c.getContext("2d").getImageData(0, 0, c.width, c.height).data; let x0 = c.width, x1 = -1, y0 = c.height, y1 = -1; for (let y = 0, j = 0; y < c.height; y++) for (let x = 0; x < c.width; x++, j += 4) if (d[j] < 128) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; } return { left: x0, right: c.width - 1 - x1, top: y0, bottom: c.height - 1 - y1, h: c.height }; })()`);
check("text keeps clear of every edge", pad.left >= 14 && pad.right >= 14 && pad.top >= 14 && pad.bottom >= 14, JSON.stringify(pad));
check("demo did not wrap: 13 lines", await run(`state.sources[0].text.trim().split("\\n").length`) === 13 && pad.h === 13 * Math.round(25 * 1.35) + 32, `height ${pad.h}`);
await shot("demo");

await run(images); await sleep(900);
check("three sheets after adding two images", await run(`state.pages.length`) === 3);
check("sidebar fits", await run(fits) === 0, String(await run(fits)));
check("tile follows the sheets, normal size", await run(`!$("tile").classList.contains("only") && $("desk").lastElementChild.id === "pick" && $("desk").children[$("desk").children.length - 2].id === "tile"`));
check("long name stays inside its sheet", await run(`[...document.querySelectorAll(".sheet")].every(s => s.querySelector(".tag").getBoundingClientRect().right <= s.getBoundingClientRect().right + .5)`));
await shot("many");

const cm0 = await run(`$("summary").textContent`);
await run(`$("more").click(); $("more").click()`);
check("copies stepper updates the summary", await run(`$("copies").value`) === "3" && (await run(`$("summary").textContent`)).startsWith("9 pages"), await run(`$("summary").textContent`));
await run(`$("less").click(); $("less").click(); $("less").click()`);
check("copies stop at 1", await run(`$("copies").value`) === "1");
await run(`document.querySelectorAll(".sheet .trash")[1].click()`); await sleep(500);
check("✕ removes a page", await run(`state.pages.length`) === 2);
await run(`$("textclose").click()`); await sleep(500);
check("closing the text card removes the text", await run(`state.pages.length === 1 && $("textcard").hidden`));

await run(`$("trim").click()`); await sleep(400);
check("switch off keeps settings on reload", await run(`JSON.parse(localStorage.getItem("s1-web-3")).trim`) === false);
await run(`$("trim").click()`); await sleep(300);
await run(`document.querySelector('#style [data-v="atkinson"]').click()`); await sleep(400);
check("style choice persists", await run(`JSON.parse(localStorage.getItem("s1-web-3")).style`) === "atkinson");
await run(`document.querySelector('#style [data-v="auto"]').click()`); await sleep(300);

const b64 = readFileSync(new URL("../../tests/fake-report.pdf", import.meta.url)).toString("base64");
await run(`(async () => { const raw = Uint8Array.from(atob("${b64}"), c => c.charCodeAt(0)); await addFiles([new File([raw], "fake-report.pdf", { type: "application/pdf" })]); })()`);
await sleep(1500);
check("two-page PDF adds two sheets", await run(`state.pages.length`) === 3);
await run(`document.querySelectorAll(".sheet .trash")[1].click()`); await sleep(800);
check("✕ on one PDF page leaves the other", await run(`state.pages.length === 2 && state.sources.length === 2`));
await run(`document.querySelectorAll(".sheet .trash")[1].click()`); await sleep(500);
check("✕ on the last PDF page removes the PDF", await run(`state.sources.length`) === 1);

// Handwritten note, with real mouse events.
await run(`state.sources.length = 0; rerender()`); await sleep(400);
await run(`$("addnote").click()`); await sleep(900);
check("empty note shows but does not print", await run(`state.pages.length === 1 && printable().length === 0 && document.querySelector(".sheet.note.blank") !== null`));
const box = JSON.parse(await run(`(() => { const r = document.querySelector(".ink").getBoundingClientRect(); return JSON.stringify({ x: r.x, y: r.y, w: r.width, h: r.height }); })()`));
const mouse = (type, x, y, buttons = 1) => cmd("Input.dispatchMouseEvent", { type, x, y, button: "left", buttons, clickCount: 1 });
const scribble = async (y0) => { await mouse("mousePressed", box.x + 40, box.y + y0); for (let i = 1; i <= 30; i++) await mouse("mouseMoved", box.x + 40 + i * 8, box.y + y0 + 20 * Math.sin(i / 2)); await mouse("mouseReleased", box.x + 280, box.y + y0, 0); };
await scribble(90); await sleep(500);
check("a stroke makes it printable", await run(`printable().length === 1 && document.querySelector(".sheet.note.blank") === null`), await run(`$("summary").textContent`));
const r0 = await run(`printable()[0].bits.length / BPL`);
check("blank end is cut before printing", r0 < 100, `${r0} rows of ${await run(`document.querySelector(".ink").height`)}`);
await scribble(170); await sleep(500);
check("two strokes", await run(`state.sources[0].strokes.length`) === 2);
await run(`[...document.querySelectorAll(".notebar button")].find(b => b.textContent === "Undo").click()`); await sleep(200);
check("undo removes one stroke", await run(`state.sources[0].strokes.length`) === 1);
await shot("note");
const grow0 = await run(`document.querySelector(".ink").height`);
await mouse("mousePressed", box.x + 60, box.y + 100);
for (let i = 1; i <= 25; i++) await mouse("mouseMoved", box.x + 60, box.y + 100 + i * 12);
await mouse("mouseReleased", box.x + 60, box.y + 400, 0); await sleep(500);
check("paper grows while writing", await run(`document.querySelector(".ink").height`) > grow0, `${grow0} -> ${await run(`document.querySelector(".ink").height`)}`);
await run(`[...document.querySelectorAll(".notebar button")].find(b => b.textContent === "Clear").click()`); await sleep(200);
check("clear empties the note", await run(`state.sources[0].strokes.length === 0 && printable().length === 0`));
await run(`document.querySelector(".sheet .trash").click()`); await sleep(400);
check("trash deletes the note", await run(`state.sources.length`) === 0);

// Stop button, with a simulated printer.
await run(`$("demo").click()`); await sleep(500);
await run(`printer = ble; printer.device = { name: "PPS1_TEST_BLE", gatt: { connected: true, disconnect() {} } }; printer.credits = 5; window.__sent = 0; printer.tx = { writeValueWithoutResponse: async (c) => { window.__sent += c.length; await sleep(20); printer.credits++; printer.wake?.(); } }; updateSummary();`);
check("connected: button says Print", await run(`$("printLabel").textContent`) === "Print");
await run(`$("print").click()`); await sleep(400);
check("printing: red stop button replaces print", await run(`$("print").hidden && !$("cancel").hidden && !$("cancel").disabled`));
await shot("printing");
await run(`$("cancel").click()`);
check("stop reacts at once", await run(`$("cancel").disabled && $("cancel").lastChild.textContent === "Stopping…"`));
await sleep(4300);
check("after stop: print is back", await run(`!$("print").hidden && $("cancel").hidden`), `toast: ${await run(`$("toast").textContent`)}`);
await run(`printer.device = null; state.sources.length = 0; rerender()`); await sleep(300);

await size(390, 800); await sleep(400);
await run(`window.scrollTo(0, 0)`);
check("phone width: no sideways page scroll", await run(`document.documentElement.scrollWidth <= innerWidth`));
await shot("phone");

// Small text: a shrunk A4 page warns and can print as text; a label that fills the paper does not.
await size(1300, 900);
await cmd("Page.navigate", { url: "http://localhost:8802/?theme=light" });
await sleep(1500);
await run(`(async () => { const raw = Uint8Array.from(atob("${b64}"), c => c.charCodeAt(0)); await addFiles([new File([raw], "fake-report.pdf", { type: "application/pdf" })]); })()`);
await sleep(1500);
const sheetNote = (i) => `document.querySelectorAll(".sheet")[${i}].querySelector(".textnotice")`;
check("a shrunk A4 page warns about small text", await run(`state.pages[0].item.smallText && ${sheetNote(0)}.textContent.includes("Print as text")`));
check("a label that fills the paper does not", await run(`!state.pages[1].item.smallText && !${sheetNote(1)}`));
const pictureRows = await run(`state.pages[0].preview.height`);
await shot("small_text");
await run(`${sheetNote(0)}.querySelector("button").click()`);
await sleep(1200);
check("Print as text replaces the page", await run(`state.pages[0].item.asText && state.pages[0].preview.height > ${pictureRows} && ${sheetNote(0)}.textContent.includes("Show original page")`));
check("each table row stays on one line", await run(`state.pages[0].item.text.includes("Sample B 13.8 g/dL 12.0 to 16.0\\n") && state.pages[0].item.text.includes("Sample C 0.82 mg/dL 0.60 to 1.10")`));
check("the text keeps the page's order", await run(`state.pages[0].item.text.indexOf("Reason for visit") < state.pages[0].item.text.indexOf("Results")`));
check("the other page keeps its picture", await run(`!state.pages[1].item.asText`));
await shot("as_text");
await run(`${sheetNote(0)}.querySelector("button").click()`);
await sleep(1200);
check("Show original brings the picture back", await run(`!state.pages[0].item.asText && state.pages[0].preview.height === ${pictureRows}`));

await size(1300, 900);
await cmd("Page.navigate", { url: "http://localhost:8802/?theme=light" });
await sleep(1500);
await shot("empty_light");
console.log("requests:", [...new Set(net)].join(" , "));
console.log("errors:", log.join(" | ") || "(none)");
console.log(failed ? `${failed} FAILED` : "all passed");
ws.close();
