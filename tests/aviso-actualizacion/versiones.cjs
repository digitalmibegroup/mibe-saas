'use strict';
/* Prepara las "versiones" que sirve el servidor de pruebas, SIEMPRE con los archivos reales de deploy/:
   - publicada : lo que esta publicado hoy (commit b502f93: service worker lacava-v2, sin aviso). Para probar la transicion.
   - v1        : deploy/ de esta rama (aviso de actualizacion, sello A).
   - v2        : v1 con un cambio visible en la pagina (titulo) y su propio sello B: la "version nueva".
   - mixta     : pagina de v1 con el service worker de v2 (un despliegue a medias): la instalacion debe rechazarse. */
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { execFileSync } = require('node:child_process');
const { calcular, conSello, MARCA_HTML, MARCA_SW } = require('../../scripts/sellar-version.cjs');
const RAIZ = path.join(__dirname, '..', '..');
const COMMIT_PUBLICADO = process.env.LACAVA_REV_PUBLICADA || 'b502f93';

function copiar(origen, destino) { fs.cpSync(origen, destino, { recursive: true }); }
function sellar(dir, htmlTexto, swTexto) {
  const s = calcular(htmlTexto, swTexto);
  fs.writeFileSync(path.join(dir, 'dashboard_lacava.html'), conSello(htmlTexto, MARCA_HTML, s));
  fs.writeFileSync(path.join(dir, 'index.html'), conSello(htmlTexto, MARCA_HTML, s));
  fs.writeFileSync(path.join(dir, 'sw.js'), conSello(swTexto, MARCA_SW, s));
  return s;
}
function publicadaDisponible() {
  try { execFileSync('git', ['cat-file', '-e', COMMIT_PUBLICADO + ':deploy/sw.js'], { cwd: RAIZ, stdio: 'ignore' }); return true; } catch { return false; }
}
function preparar() {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'lc-versiones-'));
  const dirs = {};
  dirs.v1 = path.join(base, 'v1'); copiar(path.join(RAIZ, 'deploy'), dirs.v1);
  const html1 = fs.readFileSync(path.join(dirs.v1, 'dashboard_lacava.html'), 'utf8'), sw1 = fs.readFileSync(path.join(dirs.v1, 'sw.js'), 'utf8');
  const sello1 = conSello(html1, MARCA_HTML, calcular(html1, sw1)) === html1 ? calcular(html1, sw1) : null;
  if (!sello1) throw new Error('deploy/ no esta sellado: ejecute node scripts/sellar-version.cjs');
  dirs.v2 = path.join(base, 'v2'); copiar(dirs.v1, dirs.v2);
  const html2 = html1.replace('<title>', '<title>[v2] ');
  if (html2 === html1) throw new Error('no se pudo crear la version 2 (falta <title>)');
  const sello2 = sellar(dirs.v2, html2, sw1);
  dirs.mixta = path.join(base, 'mixta'); copiar(dirs.v1, dirs.mixta);
  fs.writeFileSync(path.join(dirs.mixta, 'sw.js'), fs.readFileSync(path.join(dirs.v2, 'sw.js'), 'utf8'));   /* sw de v2 con la pagina de v1 */
  if (publicadaDisponible()) {
    dirs.publicada = path.join(base, 'publicada'); fs.mkdirSync(dirs.publicada);
    const archivos = execFileSync('git', ['ls-tree', '-r', '--name-only', COMMIT_PUBLICADO, 'deploy'], { cwd: RAIZ, encoding: 'utf8' }).split('\n').filter(Boolean);
    for (const a of archivos) {   /* los bytes exactos del commit publicado */
      const destino = path.join(dirs.publicada, a.slice('deploy/'.length));
      fs.mkdirSync(path.dirname(destino), { recursive: true });
      fs.writeFileSync(destino, execFileSync('git', ['show', COMMIT_PUBLICADO + ':' + a], { cwd: RAIZ, maxBuffer: 64 * 1024 * 1024 }));
    }
  }
  return { dirs, sello1, sello2, limpiar: () => fs.rmSync(base, { recursive: true, force: true }) };
}
module.exports = { preparar, COMMIT_PUBLICADO };
