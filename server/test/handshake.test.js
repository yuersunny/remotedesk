import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WebSocket } from 'ws';
import { createSignalingServer } from '../src/server.js';

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

test('two devices register, pair, and relay offer/answer/ice', async (t) => {
  const server = createSignalingServer({ port: 0, quiet: true });
  const { port } = await server.listen();
  const url = `ws://127.0.0.1:${port}/ws`;

  const a = await connect(url);
  const b = await connect(url);
  t.after(async () => {
    a.close();
    b.close();
    await server.close();
  });

  // --- register both devices ---
  const regA = once(a, 'registered');
  send(a, { type: 'register', id: 'A', name: 'controller' });
  assert.equal((await regA).id, 'A');

  const regB = once(b, 'registered');
  send(b, { type: 'register', id: 'B', name: 'target' });
  assert.equal((await regB).id, 'B');

  // --- device discovery ---
  const listP = once(a, 'devices');
  send(a, { type: 'list' });
  const list = await listP;
  assert.ok(list.devices.some((d) => d.id === 'B'), 'A should see B in device list');

  // --- connection request ---
  const incomingP = once(b, 'incoming');
  const requestedP = once(a, 'connect_requested');
  send(a, { type: 'connect', to: 'B' });
  const [incoming, requested] = await Promise.all([incomingP, requestedP]);
  assert.equal(incoming.from, 'A');
  assert.equal(requested.to, 'B');

  // --- accept ---
  const acceptedP = once(a, 'accepted');
  send(b, { type: 'accept', to: 'A' });
  assert.equal((await acceptedP).from, 'B');

  // --- SDP offer A -> B ---
  const offerP = once(b, 'offer');
  send(a, { type: 'offer', to: 'B', sdp: 'v=0 fake-offer' });
  const offer = await offerP;
  assert.equal(offer.from, 'A');
  assert.equal(offer.sdp, 'v=0 fake-offer');

  // --- SDP answer B -> A ---
  const answerP = once(a, 'answer');
  send(b, { type: 'answer', to: 'A', sdp: 'v=0 fake-answer' });
  assert.equal((await answerP).sdp, 'v=0 fake-answer');

  // --- ICE candidate A -> B ---
  const iceP = once(b, 'ice');
  send(a, { type: 'ice', to: 'B', candidate: { candidate: 'candidate:1 1 udp 1 1.2.3.4 5000 typ host' } });
  const ice = await iceP;
  assert.equal(ice.from, 'A');
  assert.ok(ice.candidate);

  // --- leave ---
  const leftP = once(b, 'peer_left');
  send(a, { type: 'leave', to: 'B' });
  assert.equal((await leftP).from, 'A');
});

test('relays structured SDP objects and trickled ICE candidates unchanged', async (t) => {
  const server = createSignalingServer({ port: 0, quiet: true });
  const { port } = await server.listen();
  const url = `ws://127.0.0.1:${port}/ws`;

  const a = await connect(url);
  const b = await connect(url);
  t.after(async () => {
    a.close();
    b.close();
    await server.close();
  });

  const regA = once(a, 'registered');
  send(a, { type: 'register', id: 'CTRL' });
  await regA;
  const regB = once(b, 'registered');
  send(b, { type: 'register', id: 'TGT' });
  await regB;

  // M1 sends the SDP as an object ({type, sdp}), not a bare string. The relay
  // must not stringify or reshape it, otherwise setRemoteDescription fails.
  const offerSdp = { type: 'offer', sdp: 'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n' };
  const offerP = once(b, 'offer');
  send(a, { type: 'offer', to: 'TGT', sdp: offerSdp });
  const offer = await offerP;
  assert.equal(offer.from, 'CTRL');
  assert.deepEqual(offer.sdp, offerSdp);

  // Trickled candidates must arrive complete and in order.
  const candidates = [
    { candidate: 'candidate:1 1 udp 2122260223 192.168.1.5 5000 typ host', sdpMid: '0', sdpMLineIndex: 0 },
    { candidate: 'candidate:2 1 udp 1686052607 203.0.113.9 5000 typ srflx', sdpMid: '0', sdpMLineIndex: 0 },
    { candidate: 'candidate:3 1 udp 41885439 198.51.100.7 3478 typ relay', sdpMid: '0', sdpMLineIndex: 0 },
  ];
  const received = [];
  const allP = new Promise((resolve) => {
    const onMessage = (raw) => {
      const msg = JSON.parse(raw.toString());
      if (msg.type !== 'ice') return;
      received.push(msg.candidate);
      if (received.length === candidates.length) {
        b.off('message', onMessage);
        resolve();
      }
    };
    b.on('message', onMessage);
  });
  for (const candidate of candidates) {
    send(a, { type: 'ice', to: 'TGT', candidate });
  }
  await allP;
  assert.deepEqual(received, candidates);
});

test('rejects register when auth token mismatches', async (t) => {
  const server = createSignalingServer({ port: 0, quiet: true, authToken: 'secret' });
  const { port } = await server.listen();
  const url = `ws://127.0.0.1:${port}/ws`;

  const a = await connect(url);
  t.after(async () => {
    a.close();
    await server.close();
  });

  const errP = once(a, 'error');
  send(a, { type: 'register', id: 'X', token: 'wrong' });
  assert.equal((await errP).code, 'bad_token');
});

test('rejects duplicate device id while first is online', async (t) => {
  const server = createSignalingServer({ port: 0, quiet: true });
  const { port } = await server.listen();
  const url = `ws://127.0.0.1:${port}/ws`;

  const a = await connect(url);
  const b = await connect(url);
  t.after(async () => {
    a.close();
    b.close();
    await server.close();
  });

  const regP = once(a, 'registered');
  send(a, { type: 'register', id: 'DUP' });
  await regP;

  const errP = once(b, 'error');
  send(b, { type: 'register', id: 'DUP' });
  assert.equal((await errP).code, 'id_taken');
});

test('reports target_offline when connecting to unknown device', async (t) => {
  const server = createSignalingServer({ port: 0, quiet: true });
  const { port } = await server.listen();
  const url = `ws://127.0.0.1:${port}/ws`;

  const a = await connect(url);
  t.after(async () => {
    a.close();
    await server.close();
  });

  const regP = once(a, 'registered');
  send(a, { type: 'register', id: 'SOLO' });
  await regP;

  const errP = once(a, 'error');
  send(a, { type: 'connect', to: 'NOBODY' });
  assert.equal((await errP).code, 'target_offline');
});
