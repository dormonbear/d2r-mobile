// RFC 4918/9110 协议替身：真实 HTTP、条件更新及确定性故障；仅使用自造数据和测试凭据。
// RFC 4918/9110 stand-in: real HTTP, conditional updates and deterministic faults; authored data and dummy credentials only.
const http = require('http');
const crypto = require('crypto');
const blobs = new Map();
const collections = new Set(['/']);
let fault = '';
let served = [];
let lock = null;
let secondLock = null;
const hash = b => '"' + crypto.createHash('sha256').update(b).digest('hex') + '"';
http.createServer((req, res) => {
  const path = decodeURI(new URL(req.url, 'http://localhost').pathname).replace(/\/$/, '') || '/';
  const parts = [];
  req.on('data', b => parts.push(b));
  req.on('end', () => {
    const data = Buffer.concat(parts);
    const send = (code, body = Buffer.alloc(0), headers = {}) => {
      served.push({ method: req.method, path, code, ifMatch: req.headers['if-match'] || null, ifNoneMatch: req.headers['if-none-match'] || null, hasLock: !!req.headers.if });
      console.log(JSON.stringify({ method: req.method, path, code }));
      res.writeHead(code, { 'Content-Length': body.length, ...headers }); res.end(body);
    };
    if (path === '/__test__') {
      if (req.method === 'POST') {
        const command = JSON.parse(data.toString());
        if (command.reset) { blobs.clear(); collections.clear(); collections.add('/'); fault = ''; served = []; lock = null; secondLock = null; }
        if ('fault' in command) fault = command.fault;
        if (command.mutate) blobs.set('/d2r-mobile-v1/index.json', Buffer.from(JSON.stringify(command.mutate)));
      }
      return send(200, Buffer.from(JSON.stringify({ served, lockActive: !!lock, files: [...blobs.keys()], index: blobs.has('/d2r-mobile-v1/index.json') ? JSON.parse(blobs.get('/d2r-mobile-v1/index.json')) : null })));
    }
    if (fault === 'auth' || req.headers.authorization !== 'Basic dXNlcjpwYXNz') return send(401);
    if (fault === 'timeout') return setTimeout(() => send(503), 6500);
    if (fault === 'server') return send(500, Buffer.from('<html>unavailable</html>'));
    if (fault === 'redirect') return send(307, Buffer.alloc(0), { Location: 'http://127.0.0.1:1/__leak__' });
    const fnos = fault.startsWith('fnos');
    if (req.method === 'LOCK') {
      if (!fnos) return send(501);
      if (lock && fault === 'fnos-shared-lock') {
        secondLock = '<urn:uuid:' + crypto.randomUUID() + '>';
        return send(200, Buffer.from('<D:prop xmlns:D="DAV:"/>'), { 'Lock-Token': secondLock });
      }
      if (lock || fault === 'fnos-busy') return send(423);
      lock = { root: path, token: '<urn:uuid:' + crypto.randomUUID() + '>' };
      return send(200, Buffer.from('<D:prop xmlns:D="DAV:"/>'), { 'Lock-Token': lock.token });
    }
    if (req.method === 'UNLOCK') {
      if (secondLock && req.headers['lock-token'] === secondLock) { secondLock = null; return send(204); }
      if (!lock || req.headers['lock-token'] !== lock.token) return send(409);
      lock = null; return send(204);
    }
    if (fnos && ['PUT', 'DELETE', 'MKCOL'].includes(req.method)) {
      if (fault === 'fnos-expired' && path.endsWith('/index.json') && req.method === 'PUT') lock = null;
      if (fault !== 'fnos-unsafe-lock') {
        if (req.headers.if && (!lock || req.headers.if !== '(' + lock.token + ')')) return send(412);
        if (lock && (path === lock.root || path.startsWith(lock.root + '/')) && !req.headers.if) return send(423);
      }
    }
    if (fault === 'unexpected-precondition' && req.method === 'PUT' && path.includes('/probe-')) return send(412);
    if (fault === 'unwritable-root' && ['MKCOL', 'PUT'].includes(req.method)) return send(405);
    if (req.method === 'MKCOL') { if (collections.has(path)) return send(405); collections.add(path); return send(201); }
    if (req.method === 'GET') {
      if (!blobs.has(path)) return send(404);
      let body = blobs.get(path);
      if (fault === 'corrupt' && path.includes('/objects/')) body = Buffer.from('corrupt pack');
      const headers = fault === 'noetag' ? {} : { ETag: (fault === 'weak' ? 'W/' : '') + (fault === 'static-etag' ? '"unchanging"' : hash(body)) };
      return send(200, body, headers);
    }
    if (req.method === 'PUT') {
      const exists = blobs.has(path);
      if (fault === 'race' && path.endsWith('/index.json')) return send(412);
      if (fault !== 'ignore-conditions' && !fnos) {
        if (req.headers['if-none-match'] === '*' && exists) return send(412);
        if (req.headers['if-match'] && (!exists || req.headers['if-match'] !== hash(blobs.get(path)))) return send(412);
      }
      if (fault === 'fnos-delayed' && path.endsWith('/index.json')) { blobs.set(path, data); return setTimeout(() => send(201), 300); }
      blobs.set(path, data);
      if (fault === 'lost-index-response' && path.endsWith('/index.json')) return setTimeout(() => send(exists ? 204 : 201), 6500);
      return send(fnos ? 201 : exists ? 204 : 201);
    }
    if (req.method === 'DELETE') { blobs.delete(path); return send(204); }
    return send(501);
  });
}).listen(Number(process.env.PORT || 49451), '127.0.0.1');
