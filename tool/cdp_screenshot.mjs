// Usage: node cdp.mjs <port> <steps.json>
// steps: [{"viewport":[w,h]}, {"goto":url}, {"ls":{k:v}}, {"reload":1}, {"wait":ms}, {"click":[x,y]}, {"wheel":[x,y,dy]}, {"shot":file}, {"eval":js}]
import fs from 'node:fs';
const [port, stepsFile] = process.argv.slice(2);
const steps = JSON.parse(fs.readFileSync(stepsFile, 'utf8'));
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = list.find(t => t.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const pending = new Map();
ws.addEventListener('message', e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let vw = 390, vh = 844;
for (const s of steps) {
  if (s.viewport) { [vw, vh] = s.viewport; await send('Emulation.setDeviceMetricsOverride', { width: vw, height: vh, deviceScaleFactor: 2, mobile: true }); }
  if (s.goto) { await send('Page.navigate', { url: s.goto }); await sleep(s.after ?? 6000); }
  if (s.ls) { for (const [k, v] of Object.entries(s.ls)) await send('Runtime.evaluate', { expression: `localStorage.setItem(${JSON.stringify(k)}, ${JSON.stringify(v)})` }); }
  if (s.reload) { await send('Page.reload'); await sleep(6000); }
  if (s.wait) await sleep(s.wait);
  if (s.click) { const [x, y] = s.click; for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 }); await sleep(1500); }
  if (s.wheel) { const [x, y, dy] = s.wheel; await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x, y, deltaX: 0, deltaY: dy }); await sleep(1000); }
  if (s.eval) { const r = await send('Runtime.evaluate', { expression: s.eval, returnByValue: true }); console.log(JSON.stringify(r.result?.result?.value)); }
  if (s.shot) { const r = await send('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(s.shot, Buffer.from(r.result.data, 'base64')); console.log('saved', s.shot); }
}
ws.close();
