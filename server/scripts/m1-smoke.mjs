#!/usr/bin/env node
/**
 * M1 smoke test: drives two headless Chrome instances through a real
 * controller <-> target WebRTC session and reports what actually happened.
 *
 * Why this exists: compiling a Flutter app proves nothing about the media
 * pipeline. This launches the real app, lets the two instances negotiate over
 * the real signaling server, and reads the live state from `document.title`
 * (the app reports phase | resolution | fps | bitrate there in self-test mode).
 *
 * Usage:
 *   node scripts/m1-smoke.mjs
 * Env:
 *   APP_URL       default http://127.0.0.1:8080
 *   SIGNAL_URL    default ws://127.0.0.1:8787/ws
 *   HOLD_MS       how long to keep watching after both are live (default 12000)
 *   TIMEOUT_MS    overall deadline (default 60000)
 */
import { spawn } from 'node:child_process';
import { rm } from 'node:fs/promises';
import { setTimeout as sleep } from 'node:timers/promises';
import { WebSocket } from 'ws';

const CHROME = process.env.CHROME_PATH
  ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const APP_URL = process.env.APP_URL ?? 'http://127.0.0.1:8080';
const SIGNAL_URL = process.env.SIGNAL_URL ?? 'ws://127.0.0.1:8787/ws';
const HOLD_MS = Number(process.env.HOLD_MS ?? 12_000);
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS ?? 60_000);

const peers = [
  {
    key: 'target',
    port: 9222,
    profile: '/tmp/remotedesk-cdp-target',
    url: `${APP_URL}/?id=tgt1&role=target&autojoin=1&capture=fake&server=${encodeURIComponent(SIGNAL_URL)}`,
  },
  {
    key: 'controller',
    port: 9223,
    profile: '/tmp/remotedesk-cdp-controller',
    url: `${APP_URL}/?id=ctrl1&role=controller&autojoin=1&capture=fake&peer=tgt1&server=${encodeURIComponent(SIGNAL_URL)}`,
  },
];

function launch(peer) {
  const args = [
    '--headless=new',
    // Chrome's own sandbox cannot initialise inside restricted/CI shells.
    '--no-sandbox',
    '--disable-gpu',
    '--enable-unsafe-swiftshader', // software WebGL keeps CanvasKit alive
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
  child.on('error', (err) => console.error(`[${peer.key}] launch failed:`, err.message));
  return child;
}

async function waitForDevtools(port, deadline) {
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (res.ok) return;
    } catch {
      /* not up yet */
    }
    await sleep(250);
  }
  throw new Error(`devtools on ${port} never came up`);
}

async function pageTarget(port) {
  const res = await fetch(`http://127.0.0.1:${port}/json/list`);
  const targets = await res.json();
  return targets.find((t) => t.type === 'page' && t.webSocketDebuggerUrl) ?? null;
}

async function readTitle(port) {
  const target = await pageTarget(port);
  if (!target) return null;
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  try {
    await new Promise((resolve, reject) => {
      ws.once('open', resolve);
      ws.once('error', reject);
    });
    return await new Promise((resolve) => {
      const timer = setTimeout(() => resolve(null), 4000);
      ws.on('message', (raw) => {
        const msg = JSON.parse(raw.toString());
        if (msg.id === 1) {
          clearTimeout(timer);
          resolve(msg.result?.result?.value ?? null);
        }
      });
      ws.send(JSON.stringify({
        id: 1,
        method: 'Runtime.evaluate',
        params: { expression: 'document.title', returnByValue: true },
      }));
    });
  } catch {
    return null;
  } finally {
    ws.close();
  }
}

function parseTitle(title) {
  if (!title || !title.startsWith('RemoteDesk|')) return null;
  const [, role, phase, resolution, fps, kbps, rtt] = title.split('|');
  return { role, phase, resolution, fps, kbps, rtt };
}

const children = [];
let exitCode = 1;

try {
  const deadline = Date.now() + TIMEOUT_MS;
  console.log('launching two headless Chrome instances…');
  for (const peer of peers) {
    await rm(peer.profile, { recursive: true, force: true });
    children.push(launch(peer));
  }
  for (const peer of peers) await waitForDevtools(peer.port, deadline);

  let controllerLiveSince = 0;
  let lastReport = '';

  while (Date.now() < deadline) {
    const titles = {};
    for (const peer of peers) titles[peer.key] = parseTitle(await readTitle(peer.port));

    const report = peers
      .map((p) => {
        const t = titles[p.key];
        return t
          ? `${p.key.padEnd(10)} ${t.phase.padEnd(11)} ${t.resolution.padEnd(10)} ${t.fps.padEnd(8)} ${t.kbps.padEnd(11)} rtt=${t.rtt}`
          : `${p.key.padEnd(10)} (no title yet)`;
      })
      .join('\n');
    if (report !== lastReport) {
      console.log(`\n[${new Date().toISOString().slice(11, 19)}]\n${report}`);
      lastReport = report;
    }

    const controller = titles.controller;
    const target = titles.target;
    const live = controller?.phase === 'live'
      && controller.resolution !== '—'
      && controller.fps !== '—'
      && (target?.phase === 'live' || target?.phase === 'connecting');

    if (live) {
      if (!controllerLiveSince) {
        controllerLiveSince = Date.now();
        console.log('\n>>> media is flowing, holding to confirm stability…');
      } else if (Date.now() - controllerLiveSince >= HOLD_MS) {
        console.log('\nPASS: controller receives video');
        console.log(`  resolution : ${controller.resolution}`);
        console.log(`  fps        : ${controller.fps}`);
        console.log(`  bitrate    : ${controller.kbps}`);
        console.log(`  rtt        : ${controller.rtt}`);
        exitCode = 0;
        break;
      }
    } else {
      controllerLiveSince = 0;
    }
    await sleep(1000);
  }

  if (exitCode !== 0) {
    console.error('\nFAIL: never reached a live video stream within the deadline');
  }
} catch (err) {
  console.error('\nERROR:', err.message);
} finally {
  for (const child of children) {
    try {
      child.kill('SIGKILL');
    } catch {
      /* ignore */
    }
  }
  process.exit(exitCode);
}
