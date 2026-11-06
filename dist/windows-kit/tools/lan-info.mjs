// Prints the addresses to type on each machine. ASCII only: Windows console
// code pages mangle non-ASCII stdout from node.
import os from 'node:os';

const WEB_PORT = 8080;
const SIG_PORT = 8787;

const ips = [];
for (const list of Object.values(os.networkInterfaces())) {
  for (const item of list ?? []) {
    if (item.family === 'IPv4' && !item.internal) ips.push(item.address);
  }
}

const line = '-'.repeat(60);
console.log(line);
console.log('RemoteDesk addresses');
console.log(line);
if (ips.length === 0) {
  console.log('[!] No LAN IPv4 found. Is the network cable / Wi-Fi connected?');
}
for (const ip of ips) {
  console.log('This machine LAN IP : ' + ip);
  console.log('  -> other machine fills signaling: ws://' + ip + ':' + SIG_PORT + '/ws');
}
console.log('');
console.log('On THIS machine  : web page   http://localhost:' + WEB_PORT + '/');
console.log('On OTHER machine : web page   http://localhost:' + WEB_PORT + '/  (must open on ITSELF)');
console.log('');
console.log('Why localhost? Chrome only allows screen capture on a secure origin,');
console.log('and http://localhost counts as secure while http://192.168.x.x does not.');
console.log(line);
