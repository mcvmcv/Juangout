// Checks Juangout's live timeline (chapter 10) in headless Chromium against a running dev server with seed data:
//   julia --project manage.jl runserver 8765 &  then  node --experimental-websocket tools/browser_check_live.mjs http://localhost:8765
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const [base] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), "juangout-chromium-"));
const chrome = spawn("chromium", ["--headless=new", "--disable-gpu", "--no-first-run", "--remote-debugging-port=0",
  `--user-data-dir=${profile}`, "--window-size=1000,900", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
const endpoint = await new Promise((resolve, reject) => {
  let err = ""; chrome.stderr.on("data", d => { err += d; const m = err.match(/DevTools listening on (ws:\/\/\S+)/); if (m) resolve(m[1]); });
  setTimeout(() => reject(new Error("chromium didn't start\n" + err)), 20000);
});
const ws = new WebSocket(endpoint);
await new Promise(r => ws.addEventListener("open", r, { once: true }));
let nextId = 0; const pending = new Map();
ws.addEventListener("message", e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const cmd = (method, params = {}, sessionId) => { const id = ++nextId;
  ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  return new Promise((res, rej) => pending.set(id, m => m.error ? rej(new Error(method + ": " + m.error.message)) : res(m.result))); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = {};
try {
  async function page() {
    const { targetId } = await cmd("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cmd("Target.attachToTarget", { targetId, flatten: true });
    const s = (m, p) => cmd(m, p, sessionId);
    const ev = async x => { const r = await s("Runtime.evaluate", { expression: x, awaitPromise: true, returnByValue: true });
      if (r.exceptionDetails) throw new Error("evaluate: " + JSON.stringify(r.exceptionDetails)); return r.result.value; };
    const waitFor = async (x, ms = 8000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (await ev(x)) return true; await sleep(50); } return false; };
    const go = async url => { await s("Page.navigate", { url }); await sleep(300); await waitFor("document.readyState === 'complete'"); };
    await s("Page.enable"); await s("Runtime.enable");
    return { ev, waitFor, go };
  }
  const a = await page();
  await a.go(base + "/accounts/login/");
  await a.ev(`document.querySelector('#id_username').value='ann'; document.querySelector('#id_password').value='juangout-demo'; document.querySelector('form.form').submit(); true`);
  await a.waitFor("document.readyState === 'complete' && location.pathname !== '/accounts/login/'");
  out.logged_in = await a.ev("document.body.innerText.includes('Log out')");
  const b = await page();                      // same browser, so same session cookie
  await a.go(base + "/live/"); await b.go(base + "/live/");
  await sleep(1500);                           // let live.js connect both sockets
  out.b_has_compose = await b.ev("!!document.querySelector('#j-live textarea')");
  if (!out.b_has_compose) out.b_html = await b.ev("(document.querySelector('main')||document.body).innerHTML.slice(0, 600)");
  // typing in B: the count updates over the socket
  await b.ev(`(() => { const t = document.querySelector('#j-live textarea'); t.value = 'x'.repeat(290); t.dispatchEvent(new Event('input', {bubbles: true})); return true })()`);
  out.count_updates = await b.waitFor("document.querySelector('.chars-left')?.innerText.includes('-10')");
  out.count_text = await b.ev("document.querySelector('.chars-left')?.innerText");
  out.error_shown = await b.waitFor("!!document.querySelector('#j-live .errorlist')");
  // posting in B appears in A
  const body = "Live from the browser " + Date.now();
  await b.ev(`(() => { const t = document.querySelector('#j-live textarea'); t.value = ${JSON.stringify(body)}; t.dispatchEvent(new Event('input', {bubbles: true})); return true })()`);
  await sleep(400);
  await b.ev("document.querySelector('#j-live form button[type=submit]').click(); true");
  out.post_in_b = await b.waitFor(`document.querySelector('.live-posts')?.innerText.includes(${JSON.stringify(body)})`);
  out.post_in_a = await a.waitFor(`document.querySelector('.live-posts')?.innerText.includes(${JSON.stringify(body)})`);
  out.b_form_cleared = await b.ev("document.querySelector('#j-live textarea').value === ''");
  out.a_still_on_live = await a.ev("location.pathname === '/live/'");
  // a like in A, live
  const before = await a.ev("document.querySelector('.live-posts button.like').innerText");
  await a.ev("document.querySelector('.live-posts button.like').click(); true");
  out.like_live = await a.waitFor(`document.querySelector('.live-posts button.like').innerText !== ${JSON.stringify(before)}`);
  out.like_seen_in_b = await b.waitFor(`document.querySelector('.live-posts button.like').innerText !== ${JSON.stringify(before)}`);
} catch (e) { out.error = String(e); }
finally { console.log(JSON.stringify(out, null, 1)); chrome.kill(); ws.close(); rmSync(profile, { recursive: true, force: true }); process.exit(0); }
