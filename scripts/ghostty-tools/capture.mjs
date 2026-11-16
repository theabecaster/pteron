// Captures a Rex terminal data stream (rex.data.terminal.v1) to a file.
// node capture.mjs <server> <session> <block> <out> <seconds> [command-to-send]
import fs from 'node:fs';
const [server, session, block, out, secs, cmd] = process.argv.slice(2);
const wsBase = server.replace(/^https/, 'wss');
const ctl = new WebSocket(wsBase + '/api/control', 'rex.control.v1');
let nextId = 1; const pending = new Map();
const call = (method, payload) => new Promise((res, rej) => {
  const id = String(nextId++); pending.set(id, { res, rej });
  ctl.send(JSON.stringify({ type: 'request', id, method, payload }));
});
ctl.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.type === 'welcome') return welcome();
  if (m.id && pending.has(m.id)) {
    const p = pending.get(m.id); pending.delete(m.id);
    if (m.type === 'error' || m.error) p.rej(new Error(JSON.stringify(m))); else p.res(m.payload);
  }
};
ctl.onopen = () => ctl.send(JSON.stringify({ type: 'hello', api_revision: 13, client: { kind: 'app', platform: 'macos', name: 'zz-ghostty-capture', version: '0' } }));
async function welcome() {
  await call('session.attach', { session_id: session });
  const t = await call('data.connect', { session_id: session, block_id: block, data_ref_id: 'terminal', subprotocol: 'rex.data.terminal.v1' });
  const b64 = t.ticket.replace(/-/g, '+').replace(/_/g, '/');
  const ticket = Buffer.from(b64 + '='.repeat((4 - b64.length % 4) % 4), 'base64');
  const data = new WebSocket(wsBase + '/api/data', 'rex.data.terminal.v1');
  data.binaryType = 'arraybuffer';
  const chunks = []; let welcomed = false; const t0 = performance.now(); let first = 0;
  data.onopen = () => data.send(Buffer.concat([Buffer.from([1]), ticket]));
  data.onmessage = (ev) => {
    const b = Buffer.from(ev.data);
    if (!welcomed) {
      welcomed = true;
      if (b[0] !== 0x81) { console.error('rejected', b); process.exit(1); }
      const nonce = b.readBigUInt64LE(24);
      fs.writeFileSync(out + '.nonce', nonce.toString());
      console.error('welcome after', (performance.now() - t0).toFixed(1), 'ms nonce', nonce.toString());
      if (cmd) setTimeout(() => call('com.superlogical.terminal.write', { session_id: session, block_id: block, args: { data: cmd } }), 300);
      return;
    }
    if (!first) { first = performance.now(); console.error('first data after', (first - t0).toFixed(1), 'ms'); }
    chunks.push(b);
  };
  setTimeout(() => {
    const all = Buffer.concat(chunks);
    fs.writeFileSync(out, all);
    console.error('captured', all.length, 'bytes in', chunks.length, 'messages');
    data.close(1000); ctl.close(); process.exit(0);
  }, Number(secs) * 1000);
}
