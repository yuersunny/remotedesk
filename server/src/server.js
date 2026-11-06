import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';

const DEFAULT_PORT = 8787;
const HEARTBEAT_MS = 30_000;

function log(...args) {
  console.log(`[${new Date().toISOString()}]`, ...args);
}

function safeSend(ws, payload) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify(payload));
    } catch (err) {
      log('send failed:', err.message);
    }
  }
}

/**
 * Create (but do not start) the signaling server.
 *
 * Protocol (JSON over WebSocket at /ws):
 *   C->S register  {type,id?,name?,token?}       S->C registered {id,name}
 *   C->S list                                     S->C devices [{id,name}]
 *   C->S connect   {to}                           S->target incoming {from,fromName}
 *                                                 S->C connect_requested {to}
 *   C->S accept    {to,password?}                 S->C accepted {from,password?}
 *   C->S reject    {to}                           S->C rejected {from}
 *   C->S offer|answer {to,sdp}                    S->peer {type,from,sdp}
 *   C->S ice       {to,candidate}                 S->peer ice {from,candidate}
 *   C->S leave     {to}                           S->peer peer_left {from}
 *   C->S ping                                     S->C pong {ts}
 */
export function createSignalingServer(options = {}) {
  const envPort = process.env.PORT ? Number(process.env.PORT) : undefined;
  const port = options.port ?? envPort ?? DEFAULT_PORT;
  const authToken = options.authToken ?? process.env.AUTH_TOKEN ?? '';
  const quiet = options.quiet ?? false;
  const logFn = quiet ? () => {} : log;

  /** @type {Map<string, {ws: WebSocket, name: string, lastSeen: number, meta: object}>} */
  const devices = new Map();

  /**
   * Connect attempts per caller, so a wrong password cannot be brute-forced by
   * simply calling again. Unattended targets accept automatically, which makes
   * the caller-side attempt rate the only thing standing between the password
   * and the machine — the server is the right place to bound it, because the
   * caller cannot forget to apply it.
   *
   * @type {Map<string, {count: number, resetAt: number}>}
   */
  const callAttempts = new Map();
  const CALL_WINDOW_MS = 60_000;
  const CALL_MAX_PER_WINDOW = 10;

  function checkCallBudget(callerId) {
    const now = Date.now();
    const entry = callAttempts.get(callerId);
    if (!entry || now >= entry.resetAt) {
      callAttempts.set(callerId, { count: 1, resetAt: now + CALL_WINDOW_MS });
      return { ok: true };
    }
    if (entry.count >= CALL_MAX_PER_WINDOW) {
      return {
        ok: false,
        retryAfter: Math.ceil((entry.resetAt - now) / 1000),
      };
    }
    entry.count += 1;
    return { ok: true };
  }

  // Attempt counters are only useful while they are bounded.
  const attemptSweeper = setInterval(() => {
    const now = Date.now();
    for (const [id, entry] of callAttempts) {
      if (now >= entry.resetAt) callAttempts.delete(id);
    }
  }, 60_000);
  if (attemptSweeper.unref) attemptSweeper.unref();

  const httpServer = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: true, devices: devices.size, uptime: process.uptime() }));
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('not found');
  });

  const wss = new WebSocketServer({ server: httpServer, path: '/ws' });

  function deliver(toId, payload) {
    const target = devices.get(toId);
    if (!target) return false;
    safeSend(target.ws, payload);
    return true;
  }

  function broadcast(payload, exceptId) {
    for (const [id, entry] of devices) {
      if (id === exceptId) continue;
      safeSend(entry.ws, payload);
    }
  }

  function handleRegister(ws, msg) {
    if (authToken && msg.token !== authToken) {
      logFn('[register rejected] bad_token', peer);
      safeSend(ws, { type: 'error', code: 'bad_token', message: 'invalid auth token' });
      return;
    }

    let id = typeof msg.id === 'string' ? msg.id.trim() : '';
    if (!id) id = randomUUID().slice(0, 8);

    const existing = devices.get(id);
    if (existing && existing.ws !== ws && existing.ws.readyState === WebSocket.OPEN) {
      logFn('[register rejected] id_taken', id, peer);
      safeSend(ws, { type: 'error', code: 'id_taken', message: `device id "${id}" already online` });
      return;
    }

    devices.set(id, {
      ws,
      name: typeof msg.name === 'string' ? msg.name : '',
      lastSeen: Date.now(),
      meta: msg.meta && typeof msg.meta === 'object' ? msg.meta : {},
    });
    ws.deviceId = id;
    safeSend(ws, { type: 'registered', id, name: msg.name || '' });
    logFn('register', id, msg.name || '');
  }

  wss.on('connection', (ws) => {
    ws.deviceId = null;
    ws.isAlive = true;
    // 每个到达的 TCP 都记一行，注册与否都记。"一台机器根本没连上"和"连上了但
    // 注册被拒"是两种完全不同的故障，在补这行之前它们在日志里长得一模一样。
    const peer = `${ws._socket?.remoteAddress || '?'}:${ws._socket?.remotePort || '?'}`;
    logFn('[conn]', peer);
    ws.on('pong', () => {
      ws.isAlive = true;
    });

    ws.on('message', (raw) => {
      let msg;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        safeSend(ws, { type: 'error', code: 'bad_json' });
        return;
      }
      if (!msg || typeof msg !== 'object') {
        safeSend(ws, { type: 'error', code: 'bad_json' });
        return;
      }

      const type = msg.type;
      logFn('[msg]', type, 'from', ws.deviceId || '(unregistered)', peer,
        msg.to ? `to=${msg.to}` : '');

      if (type === 'register') {
        handleRegister(ws, msg);
        return;
      }

      if (!ws.deviceId) {
        safeSend(ws, { type: 'error', code: 'not_registered' });
        return;
      }

      const self = devices.get(ws.deviceId);
      if (self) self.lastSeen = Date.now();

      switch (type) {
        case 'list': {
          const list = [];
          for (const [id, entry] of devices) {
            if (id === ws.deviceId) continue;
            list.push({ id, name: entry.name });
          }
          safeSend(ws, { type: 'devices', devices: list });
          return;
        }

        case 'connect': {
          const to = msg.to;
          if (typeof to !== 'string' || !to) {
            safeSend(ws, { type: 'error', code: 'no_target' });
            return;
          }
          const budget = checkCallBudget(ws.deviceId || 'anonymous');
          if (!budget.ok) {
            logFn(`[connect throttled] ${ws.deviceId} -> ${to} retry=${budget.retryAfter}s`);
            safeSend(ws, {
              type: 'error',
              code: 'rate_limited',
              message: `尝试过于频繁，请 ${budget.retryAfter} 秒后重试`,
            });
            return;
          }
          const target = devices.get(to);
          if (!target) {
            safeSend(ws, { type: 'error', code: 'target_offline', to });
            return;
          }
          // The password travels with the request: an unattended target has to
          // check it itself, and the server has no business holding it. The
          // server's job is the attempt limit above, which a caller cannot skip.
          const password = typeof msg.password === 'string' ? msg.password : '';
          safeSend(target.ws, {
            type: 'incoming',
            from: ws.deviceId,
            fromName: self?.name || '',
            requiresPassword: password.length > 0,
            password,
          });
          safeSend(ws, { type: 'connect_requested', to });
          return;
        }

        case 'accept':
        case 'reject': {
          const to = msg.to;
          if (typeof to !== 'string' || !to) {
            safeSend(ws, { type: 'error', code: 'no_target' });
            return;
          }
          const payload = { type: type === 'accept' ? 'accepted' : 'rejected', from: ws.deviceId };
          if (type === 'accept' && typeof msg.password === 'string') payload.password = msg.password;
          if (!deliver(to, payload)) {
            safeSend(ws, { type: 'error', code: 'target_offline', to });
          }
          return;
        }

        case 'offer':
        case 'answer':
        case 'ice':
        case 'candidate': {
          const to = msg.to;
          if (typeof to !== 'string' || !to) {
            safeSend(ws, { type: 'error', code: 'no_target' });
            return;
          }
          const payload = { type, from: ws.deviceId };
          if (msg.sdp !== undefined) payload.sdp = msg.sdp;
          if (msg.candidate !== undefined) payload.candidate = msg.candidate;
          if (!deliver(to, payload)) {
            safeSend(ws, { type: 'error', code: 'target_offline', to });
          }
          return;
        }

        case 'leave': {
          if (typeof msg.to === 'string' && msg.to) {
            deliver(msg.to, { type: 'peer_left', from: ws.deviceId });
          }
          return;
        }

        case 'ping': {
          safeSend(ws, { type: 'pong', ts: Date.now() });
          return;
        }

        default: {
          safeSend(ws, { type: 'error', code: 'unknown_type', got: String(type) });
        }
      }
    });

    ws.on('close', () => {
      if (!ws.deviceId) {
        logFn('[gone]', peer, '(never registered)');
        return;
      }
      const entry = devices.get(ws.deviceId);
      if (entry && entry.ws === ws) {
        devices.delete(ws.deviceId);
        logFn('disconnect', ws.deviceId);
        broadcast({ type: 'peer_offline', id: ws.deviceId }, ws.deviceId);
      }
    });

    ws.on('error', (err) => logFn('ws error:', err.message));
  });

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws.isAlive === false) {
        ws.terminate();
        continue;
      }
      ws.isAlive = false;
      try {
        ws.ping();
      } catch {
        /* ignore */
      }
    }
  }, HEARTBEAT_MS);
  heartbeat.unref?.();

  function listen() {
    return new Promise((resolve, reject) => {
      httpServer.once('error', reject);
      httpServer.listen(port, () => {
        const addr = httpServer.address();
        resolve({ port: typeof addr === 'object' && addr ? addr.port : port });
      });
    });
  }

  async function close() {
    clearInterval(heartbeat);
    for (const ws of wss.clients) {
      try {
        ws.terminate();
      } catch {
        /* ignore */
      }
    }
    await new Promise((resolve) => wss.close(() => resolve()));
    await new Promise((resolve) => httpServer.close(() => resolve()));
  }

  return { httpServer, wss, devices, listen, close, authToken };
}
