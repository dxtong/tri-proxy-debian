// 一次性容器的雙棧 HTTP／DNS；非測試網域交回原本的 DNS。
const http = require('node:http');
const dgram = require('node:dgram');
const upstream = process.env.TRI_DNS_UPSTREAM;
if (!upstream) throw new Error('缺少測試 DNS 上游');

for (const [host, value, ports] of [
  ['127.0.0.1', 'egress-v4', [25447, 25448]],
  ['::1', 'egress-v6', [25447, 25449]],
]) {
  for (const port of ports) {
    http.createServer((req, res) => res.end(value)).listen({ host, port, ipv6Only: true });
  }
}

const dns = dgram.createSocket('udp4');
dns.on('message', (query, remote) => {
  let offset = 12;
  const labels = [];
  while (query[offset]) {
    const size = query[offset++];
    labels.push(query.subarray(offset, offset + size).toString());
    offset += size;
  }
  const type = query.readUInt16BE(offset + 1);
  const name = labels.join('.');
  if (!['tri-v4.test', 'tri-v6.test', 'tri-dual.test'].includes(name)) {
    const forward = dgram.createSocket(upstream.includes(':') ? 'udp6' : 'udp4');
    const timer = setTimeout(() => forward.close(), 2000);
    forward.once('message', response => {
      dns.send(response, remote.port, remote.address);
      clearTimeout(timer);
      forward.close();
    });
    forward.on('error', () => { clearTimeout(timer); forward.close(); });
    forward.send(query, 53, upstream);
    return;
  }
  const address = type === 1 && name !== 'tri-v6.test' ? Buffer.from([127, 0, 0, 1])
    : type === 28 && name !== 'tri-v4.test' ? Buffer.from('00000000000000000000000000000001', 'hex')
    : null;
  const header = Buffer.from(query.subarray(0, 12));
  header.writeUInt16BE(0x8180, 2);
  header.writeUInt16BE(address ? 1 : 0, 6);
  header.writeUInt16BE(0, 8);
  header.writeUInt16BE(0, 10);
  const question = query.subarray(12, offset + 5);
  const answer = Buffer.alloc(12);
  answer.writeUInt16BE(0xc00c, 0);
  answer.writeUInt16BE(type, 2);
  answer.writeUInt16BE(1, 4);
  answer.writeUInt32BE(1, 6);
  answer.writeUInt16BE(address?.length ?? 0, 10);
  dns.send(Buffer.concat(address ? [header, question, answer, address] : [header, question]), remote.port, remote.address);
});
dns.bind(53, '127.0.0.1');
