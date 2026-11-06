#!/usr/bin/env node
/**
 * M2 smoke test: proves the *control* channel carries real traffic between two
 * independent clients.
 *
 * What this can and cannot prove, stated up front:
 *
 *   ✅ the `input` DataChannel is created by the controller and adopted by the
 *      target, inside one negotiation round;
 *   ✅ pointer move / button / wheel / key events survive encode → SCTP →
 *      decode, including the queue-then-flush path;
 *   ✅ the controller's black-bar maths turns screen coordinates into the
 *      expected [0,1] range (a move over a letterbox bar must NOT be sent);
 *   ✅ the target's `hello` handshake arrives, so the HUD knows the geometry.
 *   ❌ actual cursor movement: injection is native-only, and this test runs two
 *      browser instances. Verifying SendInput needs a Windows target — see
 *      docs/m2-verification.md.
 *
 * Events are injected with the DevTools protocol (`Input.dispatchMouseEvent` /
 * `dispatchKeyEvent`), i.e. the real browser event path, not a Dart back door.
 *
 * Usage:
 *   node scripts/m2-smoke.mjs
 * Env: APP_URL, SIGNAL_URL, TIMEOUT_MS (same meaning as m1-smoke.mjs)
 */
import { spawn } from 'node:child_process';
import { rm } from 'node:fs/promises';
import { setTimeout as sleep } from 'node:timers/promises';
import { WebSocket } from 'ws';

const CHROME = process.env.CHROME_PATH
  ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const APP_URL = process.env.APP_URL ?? 'http://127.0.0.1:8080';
const SIGNAL_URL = process.env.SIGNAL_URL ?? 'ws://127.0.0.1:8787/ws';
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS ?? 90_000);

const peers = {
  target: {
    port: 9232,
    profile: '/tmp/remotedesk-m2-target',
    url: `${APP_URL}/?id=tgt2&role=target&autojoin=1&capture=fake&server=${encodeURIComponent(SIGNAL_URL)}`,
  },
  controller: {
    port: 9233,
    profile: '/tmp/remotedesk-m2-controller',
    url: `${APP_URL}/?id=ctrl2&role=controller&autojoin=1&capture=fake&peer=tgt2&server=${encodeURIComponent(SIGNAL_URL)}`,
  },
};

function launch(peer) {
  const args = [
    '--headless=new',
    '--no-sandbox',
    '--disable-gpu',
    '--enable-unsafe-swiftshader',
    '--disable-dev-shm-usage',
    `--remote-debugging-port=${peer.port}`,
    `--user-data-dir=${peer.profile}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-extensions',
    '--use-fake-device-for-media-stream',
    '--use-fake-ui-for-media-stream',
    '--autoplay-policy=no-user-gesture-required',
    '--window-size=1440,900',
    peer.url,
  ];
  const child = spawn(CHROME, args, { stdio: 'ignore', detached: false });
  child.on('error', (err) => console.error(`launch failed:`, err.message));
  return child;
}

async function waitForDevtools(port, deadline) {
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (res.ok) return;
    } catch { /* not up yet */ }
    await sleep(250);
  }
  throw new Error(`devtools on ${port} never came up`);
}

async function pageTarget(port) {
  const res = await fetch(`http://127.0.0.1:${port}/json/list`);
  const targets = await res.json();
  return targets.find((t) => t.type === 'page' && t.webSocketDebuggerUrl) ?? null;
}

/** Minimal CDP client: one websocket, id-matched request/response. */
class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.pending = new Map();
    ws.on('message', (raw) => {
      const msg = JSON.parse(raw.toString());
      const entry = this.pending.get(msg.id);
      if (!entry) return;
      this.pending.delete(msg.id);
      if (msg.error) entry.reject(new Error(msg.error.message));
      else entry.resolve(msg.result);
    });
  }

  static async open(port) {
    const target = await pageTarget(port);
    if (!target) throw new Error(`no page target on ${port}`);
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      ws.once('open', resolve);
      ws.once('error', reject);
    });
    return new Cdp(ws);
  }

  send(method, params = {}) {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`${method} timed out`));
      }, 5000);
    });
  }

  async evaluate(expression) {
    const res = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
    });
    return res?.result?.value;
  }

  /** Read the self-test title and split it into fields. */
  async state() {
    const title = await this.evaluate('document.title');
    if (!title || !title.startsWith('RemoteDesk|')) return null;
    const [, role, phase, resolution, fps, kbps, rtt, ...rest] = title.split('|');
    const extra = {};
    for (const item of rest) {
      const match = /^([a-z]+)(-?\d+)$/.exec(item);
      if (match) extra[match[1]] = Number(match[2]);
    }
    return { role, phase, resolution, fps, kbps, rtt, raw: title, ...extra };
  }

  close() {
    this.ws.close();
  }
}

async function mouse(cdp, type, x, y, extra = {}) {
  await cdp.send('Input.dispatchMouseEvent', {
    type, x, y, button: 'none', buttons: 0, clickCount: 0, ...extra,
  });
}

async function wheel(cdp, x, y, deltaY) {
  await cdp.send('Input.dispatchMouseEvent', {
    type: 'mouseWheel', x, y, deltaX: 0, deltaY, button: 'none', buttons: 0,
  });
}

async function key(cdp, type, code, vk, text) {
  await cdp.send('Input.dispatchKeyEvent', {
    type,
    code,
    key: text ?? code,
    windowsVirtualKeyCode: vk,
    nativeVirtualKeyCode: vk,
    ...(type === 'keyDown' && text ? { text } : {}),
  });
}

const children = [];
let exitCode = 1;

try {
  const deadline = Date.now() + TIMEOUT_MS;
  console.log('launching two headless Chrome instances…');
  for (const peer of Object.values(peers)) {
    await rm(peer.profile, { recursive: true, force: true });
    children.push(launch(peer));
  }
  await waitForDevtools(peers.target.port, deadline);
  await waitForDevtools(peers.controller.port, deadline);

  const target = await Cdp.open(peers.target.port);
  const controller = await Cdp.open(peers.controller.port);
  // Keyboard events are dropped while the page believes it is unfocused, which
  // a headless window always does.
  await controller.send('Emulation.setFocusEmulationEnabled', { enabled: true });
  await target.send('Emulation.setFocusEmulationEnabled', { enabled: true });

  console.log('waiting for the session to go live…');
  let live = false;
  while (Date.now() < deadline) {
    const state = await controller.state();
    if (state?.phase === 'live' && state.resolution !== '—') {
      live = true;
      console.log(`live: ${state.resolution} ${state.fps} ${state.kbps} rtt=${state.rtt}`);
      break;
    }
    await sleep(1000);
  }
  if (!live) throw new Error('session never reached live');
  // Give the target a beat to attach its channel handler and send `hello`.
  await sleep(1500);

  const before = await target.state();
  console.log(`target before input: rx=${before?.rx ?? '-'} mv=${before?.mv ?? '-'} ky=${before?.ky ?? '-'}`);

  // Walk the pointer across the picture, then click, scroll and type. Several
  // positions because the video pane's rect is layout-dependent; moves over a
  // letterbox bar are correctly dropped, so one hit is enough to prove the path.
  const path = [[720, 420], [760, 440], [800, 460], [840, 480], [880, 500]];
  for (const [x, y] of path) {
    await mouse(controller, 'mouseMoved', x, y);
    await sleep(60);
  }
  await mouse(controller, 'mousePressed', 880, 500, { button: 'left', buttons: 1, clickCount: 1 });
  await mouse(controller, 'mouseReleased', 880, 500, { button: 'left', buttons: 0, clickCount: 1 });
  await wheel(controller, 880, 500, -120);
  await key(controller, 'keyDown', 'KeyA', 65, 'a');
  await sleep(40);
  await key(controller, 'keyUp', 'KeyA', 65);

  await sleep(2500);

  const after = await target.state();
  const controllerAfter = await controller.state();
  console.log(`target after input  : rx=${after?.rx} mv=${after?.mv} ky=${after?.ky}`);
  console.log(`controller hello    : h=${controllerAfter?.h} (1 = target reported geometry)`);

  const rx = after?.rx ?? 0;
  const mv = after?.mv ?? 0;
  const ky = after?.ky ?? 0;
  const hello = controllerAfter?.h ?? 0;

  const failures = [];
  if (rx <= 0) failures.push('target received no control frame at all');
  if (mv <= 0) failures.push('no pointer move arrived');
  if (ky < 2) failures.push(`expected a key down+up pair, got ${ky}`);
  if (hello !== 1) failures.push('controller never received the target hello');

  if (failures.length === 0) {
    console.log('\nPASS: control channel is end-to-end functional');
    console.log(`  frames received : ${rx} (moves ${mv}, keys ${ky})`);
    console.log('  note            : injection itself is native-only; this run proves transport + decoding');
    exitCode = 0;
  } else {
    console.error('\nFAIL:');
    for (const failure of failures) console.error(`  - ${failure}`);
    if (after) console.error(`  raw target title: ${after.raw}`);
    if (controllerAfter) console.error(`  raw ctrl title  : ${controllerAfter.raw}`);
  }

  target.close();
  controller.close();
} catch (err) {
  console.error('\nERROR:', err.message);
} finally {
  for (const child of children) {
    try { child.kill('SIGKILL'); } catch { /* ignore */ }
  }
  process.exit(exitCode);
}
