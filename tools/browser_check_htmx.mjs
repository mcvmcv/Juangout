// Checks Juangout's htmx behaviour in headless Chromium against a running dev server with seed data:
//   julia --project manage.jl runserver 8765 &  then  node --experimental-websocket tools/browser_check_htmx.mjs http://localhost:8765
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
  const { targetId } = await cmd("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cmd("Target.attachToTarget", { targetId, flatten: true });
  const s = (m, p) => cmd(m, p, sessionId);
  const ev = async x => { const r = await s("Runtime.evaluate", { expression: x, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error("evaluate: " + JSON.stringify(r.exceptionDetails)); return r.result.value; };
  const waitFor = async (x, ms = 8000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (await ev(x)) return true; await sleep(50); } return false; };
  const go = async url => { await s("Page.navigate", { url }); await sleep(300); await waitFor("document.readyState === 'complete'"); };
  await s("Page.enable"); await s("Runtime.enable");
  // log in
  await go(base + "/accounts/login/");
  await ev(`document.querySelector('#id_username').value='ann'; document.querySelector('#id_password').value='juangout-demo'; document.querySelector('form.form').submit(); true`);
  await sleep(500); await waitFor("document.readyState === 'complete'");
  out.logged_in = await ev("document.body.innerText.includes('Log out')");
  out.htmx_loaded = await ev("typeof htmx !== 'undefined'");
  // like without a reload
  await go(base + "/everyone/");
  await ev("window.__marker = 42; true");
  const before = await ev("document.querySelector('button.like').innerText");
  await ev("document.querySelector('button.like').click(); true");
  out.like_changed = await waitFor(`document.querySelector('button.like').innerText !== ${JSON.stringify(before)}`);
  out.like_before_after = [before, await ev("document.querySelector('button.like').innerText")];
  out.like_no_reload = await ev("window.__marker === 42");
  // post without a reload
  await go(base + "/");
  await ev("window.__marker = 7; true");
  const body = "Browser test post " + Date.now();
  await ev(`document.querySelector('form.compose textarea').value = ${JSON.stringify(body)}; document.querySelector('form.compose button').click(); true`);
  out.post_inserted = await waitFor(`document.querySelector('#post-list .post .body')?.innerText.includes(${JSON.stringify(body)})`);
  out.form_cleared = await ev("document.querySelector('form.compose textarea').value === ''");
  out.message_shown = await waitFor("document.querySelector('#messages')?.innerText.includes('Posted.')");
  out.post_no_reload = await ev("window.__marker === 7");
  // an invalid post shows errors in place
  await ev("document.querySelector('form.compose textarea').value=''; document.querySelector('form.compose textarea').removeAttribute('required'); document.querySelector('form.compose button').click(); true");
  out.error_in_place = await waitFor("!!document.querySelector('form.compose .errorlist')");
  // infinite scroll
  await go(base + "/everyone/");
  const n0 = await ev("document.querySelectorAll('#post-list .post').length");
  out.load_more_present = await ev("!!document.querySelector('.load-more')");
  await ev("window.scrollTo(0, document.body.scrollHeight); true");
  out.more_loaded = await waitFor(`document.querySelectorAll('#post-list .post').length > ${n0}`);
  out.posts_before_after = [n0, await ev("document.querySelectorAll('#post-list .post').length")];
  // follow without a reload
  await go(base + "/@dee/");
  const fb = await ev("document.querySelector('#follow-box button').innerText");
  await ev("document.querySelector('#follow-box button').click(); true");
  out.follow_toggled = await waitFor(`document.querySelector('#follow-box button')?.innerText !== ${JSON.stringify(fb)}`);
  out.follow_before_after = [fb, await ev("document.querySelector('#follow-box button').innerText")];
} catch (e) { out.error = String(e); }
finally { console.log(JSON.stringify(out, null, 1)); chrome.kill(); ws.close(); rmSync(profile, { recursive: true, force: true }); process.exit(0); }
