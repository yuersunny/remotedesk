import { createSignalingServer } from './src/server.js';

const server = createSignalingServer();
const { port } = await server.listen();

console.log(`[signaling] listening on :${port}`);
console.log(`[signaling]   ws      : ws://0.0.0.0:${port}/ws`);
console.log(`[signaling]   health  : http://0.0.0.0:${port}/health`);
console.log(`[signaling]   auth    : ${server.authToken ? 'enabled (AUTH_TOKEN set)' : 'disabled'}`);

async function shutdown(signal) {
  console.log(`\n[signaling] ${signal} received, shutting down...`);
  try {
    await server.close();
  } finally {
    process.exit(0);
  }
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
