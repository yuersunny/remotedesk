import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WebSocket } from 'ws';
import { createSignalingServer } from '../src/server.js';

// Unattended mode is the one place where a wrong password would be the only
// thing between a stranger and someone's desktop, so the two server-side
// guarantees it depends on get their own tests: the password reaches the
// target intact, and the caller cannot retry it without limit.

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}

function once(ws, type) {
  return new Promise((resolve) => {
    const onMessage = (raw) => {
      let msg;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        return;
      }
      if (msg.type === type) {
        ws.off('message', onMessage);
        resolve(msg);
      }
    };
    ws.on('message', onMessage);
  });
}

function send(ws, obj) {
  ws.send(JSON.stringify(obj));
}

async function pair(t) {
  const server = createSignalingServer({ port: 0, quiet: true });
  const { port } = await server.listen();
  const url = `ws://127.0.0.1:${port}/ws`;

  const caller = await connect(url);
  const target = await connect(url);
  t.after(async () => {
    caller.close();
    target.close();
    await server.close();
  });

  const regCaller = once(caller, 'registered');
  send(caller, { type: 'register', id: 'home', name: 'controller' });
  await regCaller;

  const regTarget = once(target, 'registered');
  send(target, { type: 'register', id: 'office', name: 'target' });
  await regTarget;

  return { caller, target };
}

test('forwards the password itself, not just the fact that one exists', async (t) => {
  const { caller, target } = await pair(t);

  const incoming = once(target, 'incoming');
  send(caller, { type: 'connect', to: 'office', password: 'hunter2-长口令' });
  const msg = await incoming;

  // The target has to compare this value, so a boolean would be useless.
  assert.equal(msg.password, 'hunter2-长口令');
  assert.equal(msg.requiresPassword, true);
  assert.equal(msg.from, 'home');
});

test('marks a password-less call so a locked target can refuse it', async (t) => {
  const { caller, target } = await pair(t);

  const incoming = once(target, 'incoming');
  send(caller, { type: 'connect', to: 'office' });
  const msg = await incoming;

  assert.equal(msg.password, '');
  assert.equal(msg.requiresPassword, false);
});

test('throttles repeat attempts so a password cannot be brute-forced', async (t) => {
  const { caller, target } = await pair(t);

  // The target sees one `incoming` per allowed attempt; counting them is the
  // honest way to assert that the budget was spent rather than guessed.
  let incoming = 0;
  target.on('message', (raw) => {
    try {
      if (JSON.parse(raw.toString()).type === 'incoming') incoming += 1;
    } catch {
      // ignore non-JSON
    }
  });

  const WINDOW_MAX = 10;
  for (let i = 0; i < WINDOW_MAX; i++) {
    send(caller, { type: 'connect', to: 'office', password: `guess-${i}` });
  }

  const errP = once(caller, 'error');
  send(caller, { type: 'connect', to: 'office', password: 'one-too-many' });
  const err = await errP;

  assert.equal(err.code, 'rate_limited');
  assert.match(err.message, /秒后重试/);

  // Give the queued frames a moment, then check the budget held at the limit.
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(incoming, WINDOW_MAX);
});
