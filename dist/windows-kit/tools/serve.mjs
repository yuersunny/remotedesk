// Minimal static file server for the RemoteDesk web build.
//
// Why this exists: the Flutter web app only gets a *secure context* when the
// page is served from http://localhost (or https). Chrome refuses
// getDisplayMedia on http://192.168.x.x, so each machine must serve this folder
// on its OWN localhost - never open the page through the other machine's IP.
//
// Usage: node serve.mjs <dir> [port]
import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const rootArg = process.argv[2] ?? '.';
const portArg = Number(process.argv[3] ?? 8080);
const root = path.resolve(rootArg);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream',
  '.symbols': 'text/plain; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
};

function lanAddresses() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const item of list ?? []) {
      if (item.family === 'IPv4' && !item.internal) out.push(item.address);
    }
  }
  return out;
}

function send(res, code, body, headers = {}) {
  res.writeHead(code, { 'cache-control': 'no-store', ...headers });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', 'http://localhost');
    let rel = decodeURIComponent(url.pathname);
    if (rel.endsWith('/')) rel += 'index.html';

    const target = path.resolve(root, '.' + rel);
    // Never serve outside the root, even if the request tries `../`.
    if (target !== root && !target.startsWith(root + path.sep)) {
      send(res, 403, 'forbidden');
      return;
    }

    let stat;
    try {
      stat = await fsp.stat(target);
    } catch {
      send(res, 404, 'not found: ' + rel);
      return;
    }
    if (stat.isDirectory()) {
      const index = path.join(target, 'index.html');
      try {
        stat = await fsp.stat(index);
      } catch {
        send(res, 404, 'directory without index.html');
        return;
      }
      return stream(index, stat, res, req);
    }
    return stream(target, stat, res, req);
  } catch (err) {
    send(res, 500, 'server error: ' + err.message);
  }
});

function stream(file, stat, res, req) {
  const type = MIME[path.extname(file).toLowerCase()] ?? 'application/octet-stream';
  res.writeHead(200, {
    'content-type': type,
    'content-length': stat.size,
    'cache-control': 'no-store',
  });
  if (req.method === 'HEAD') {
    res.end();
    return;
  }
  fs.createReadStream(file).pipe(res);
}

server.listen(portArg, () => {
  const port = server.address().port;
  console.log('[web] serving ' + root);
  console.log('[web]   local : http://localhost:' + port + '/');
  for (const ip of lanAddresses()) {
    console.log('[web]   lan   : http://' + ip + ':' + port + '/   (no screen capture there - localhost only)');
  }
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    console.log('[web] ' + sig + ', stopping');
    server.close(() => process.exit(0));
  });
}
