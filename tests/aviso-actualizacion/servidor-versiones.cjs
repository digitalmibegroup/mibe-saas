'use strict';
/* Servidor local que imita a Netlify para las pruebas del aviso de actualizacion: sirve los archivos REALES de una carpeta deploy/
   (una "version") y permite cambiar de version sin reiniciar, como un despliegue. "/" se reescribe a dashboard_lacava.html (200),
   igual que deploy/_redirects. Cabecera de Netlify por defecto: Cache-Control public, max-age=0, must-revalidate. */
const http = require('node:http'), fs = require('node:fs'), path = require('node:path');
const TIPOS = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.json': 'application/json', '.png': 'image/png', '.css': 'text/css', '.webmanifest': 'application/manifest+json' };

function crear(versiones, activa) {
  let actual = activa;
  const registro = [];
  const servidor = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    if (url.pathname === '/__cambiar') { actual = url.searchParams.get('v'); res.end('ok ' + actual); return; }
    const dir = versiones[actual];
    let ruta = url.pathname === '/' ? '/dashboard_lacava.html' : url.pathname;
    registro.push({ t: Date.now(), ruta: url.pathname, version: actual, metodo: req.method });
    const archivo = path.join(dir, path.normalize(ruta).replace(/^([/\\])+/, ''));
    if (!archivo.startsWith(dir) || !fs.existsSync(archivo) || fs.statSync(archivo).isDirectory()) { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('404'); return; }
    res.writeHead(200, { 'content-type': TIPOS[path.extname(archivo)] || 'application/octet-stream', 'cache-control': 'public, max-age=0, must-revalidate' });
    fs.createReadStream(archivo).pipe(res);
  });
  return {
    registro,
    cambiar(v) { if (!versiones[v]) throw new Error('version desconocida ' + v); actual = v; },
    version: () => actual,
    iniciar: () => new Promise(ok => servidor.listen(0, '127.0.0.1', () => ok('http://localhost:' + servidor.address().port))),
    cerrar: () => new Promise(ok => { servidor.closeAllConnections && servidor.closeAllConnections(); servidor.close(ok); })
  };
}
module.exports = { crear };
