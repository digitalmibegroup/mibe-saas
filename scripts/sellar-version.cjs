'use strict';
/* Sella la version de La Cava: APP_BUILD (en la pagina) y BUILD (en deploy/sw.js) con el mismo valor, derivado del contenido de
   ambos archivos. Cualquier cambio en la pagina o en el service worker cambia el sello, y asi el navegador instala el service
   worker nuevo y el aviso de actualizacion se activa.

   Uso:
     node scripts/sellar-version.cjs              sella y copia la pagina a deploy/index.html y deploy/dashboard_lacava.html
     node scripts/sellar-version.cjs --verificar  no escribe nada; sale con codigo 1 si el sello o las copias no coinciden

   Fuente de la pagina: dashboard_lacava.html (raiz). Se publican las copias de deploy/. */
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');

const RAIZ = path.join(__dirname, '..');
const FUENTE = path.join(RAIZ, 'dashboard_lacava.html');
const COPIAS = [path.join(RAIZ, 'deploy', 'dashboard_lacava.html'), path.join(RAIZ, 'deploy', 'index.html')];
const SW = path.join(RAIZ, 'deploy', 'sw.js');
const MARCA_HTML = "var APP_BUILD='", MARCA_SW = "var BUILD = '", PLANTILLA = '__SELLO__';

const lf = t => t.split('\r\n').join('\n');
function leerSello(texto, marca) {
  const i = texto.indexOf(marca);
  if (i < 0) throw new Error('falta ' + marca);
  const f = texto.indexOf("'", i + marca.length);
  return { sello: texto.slice(i + marca.length, f), ini: i + marca.length, fin: f };
}
function conSello(texto, marca, valor) { const s = leerSello(texto, marca); return texto.slice(0, s.ini) + valor + texto.slice(s.fin); }
function calcular(html, sw) {
  const h = crypto.createHash('sha256');
  h.update(conSello(lf(html), MARCA_HTML, PLANTILLA)); h.update('\n--sw--\n'); h.update(conSello(lf(sw), MARCA_SW, PLANTILLA));
  return h.digest('hex').slice(0, 12);
}
function estado() {
  const html = fs.readFileSync(FUENTE, 'utf8'), sw = fs.readFileSync(SW, 'utf8');
  const esperado = calcular(html, sw);
  const problemas = [];
  const sHtml = leerSello(html, MARCA_HTML).sello, sSw = leerSello(sw, MARCA_SW).sello;
  if (sHtml !== esperado) problemas.push('APP_BUILD de la pagina (' + sHtml + ') no coincide con el calculado (' + esperado + ')');
  if (sSw !== esperado) problemas.push('BUILD de sw.js (' + sSw + ') no coincide con el calculado (' + esperado + ')');
  for (const c of COPIAS) if (!fs.existsSync(c) || fs.readFileSync(c, 'utf8') !== html) problemas.push('la copia ' + path.relative(RAIZ, c) + ' no es identica a dashboard_lacava.html');
  return { esperado, problemas, html, sw };
}

if (require.main === module) {
  if (process.argv.includes('--verificar')) {
    const e = estado();
    if (e.problemas.length) { console.error('SELLO NO VALIDO:\n - ' + e.problemas.join('\n - ')); process.exit(1); }
    console.log('sello valido: ' + e.esperado); process.exit(0);
  }
  const html0 = fs.readFileSync(FUENTE, 'utf8'), sw0 = fs.readFileSync(SW, 'utf8');
  const sello = calcular(html0, sw0);
  const html = conSello(html0, MARCA_HTML, sello), sw = conSello(sw0, MARCA_SW, sello);
  fs.writeFileSync(FUENTE, html); fs.writeFileSync(SW, sw);
  for (const c of COPIAS) fs.writeFileSync(c, html);
  console.log('sellado: ' + sello);
}
module.exports = { calcular, estado, leerSello, conSello, MARCA_HTML, MARCA_SW, PLANTILLA };
