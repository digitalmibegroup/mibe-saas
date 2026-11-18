'use strict';
/* Ensayo del GUION del ensayo: el mismo script que se usara contra PostgREST real se ejecuta aqui contra el
   adaptador local sobre un PostgreSQL TEMPORAL (datos ficticios). Valida la logica del guion y sus guardas;
   NO sustituye al ensayo en el proyecto separado (los codigos HTTP reales los confirma ese ensayo). */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { disponible, iniciar, prepararBase } = require('../pg/pg-temporal.cjs');
const { crearFetch } = require('../pg/postgrest-shim.cjs');
const { ejecutar, HUELLA_PRODUCCION, sha } = require('./ensayo-postgrest.cjs');

let pg = null;
const SKIP = !disponible() && 'PostgreSQL portable no disponible';
before(() => { if (SKIP) return; pg = iniciar(); prepararBase(pg); });
after(() => { if (pg) pg.detener(); });

test('el guion completo pasa contra el adaptador local (todas las comprobaciones)', { skip: SKIP }, async () => {
  const lineas = [];
  const r = await ejecutar({ url: 'https://aaaaaaaaaaaaaaaaaaaa.supabase.co', key: 'clave-ficticia-local-0000', fetchFn: crearFetch(pg), log: l => lineas.push(l) });
  const malas = r.resultados.filter(x => !x.ok);
  assert.equal(malas.length, 0, 'fallaron: ' + JSON.stringify(malas, null, 1));
  assert.ok(r.total >= 25, 'comprobaciones: ' + r.total);
  /* el guion deja evidencia de los datos ficticios, nunca datos reales */
  assert.equal(pg.sql(`SELECT count(*) FROM ventas WHERE cliente_nombre NOT LIKE '%(ENSAYO)%'`).out, '0');
  assert.ok(lineas.some(l => /Resumen: \d+ de \d+ comprobaciones correctas\./.test(l)));
});
test('el guion se detiene si la función no está instalada', { skip: SKIP }, async () => {
  const r = pg.archivoSeguro(path.join(__dirname, '..', '..', '..', 'HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql'));
  assert.ok(r.ok, r.err);
  try {
    await assert.rejects(() => ejecutar({ url: 'https://aaaaaaaaaaaaaaaaaaaa.supabase.co', key: 'clave-ficticia-local-0000', fetchFn: crearFetch(pg), log() {} }), /no está instalada/);
  } finally { pg.archivo(path.join(__dirname, '..', '..', '..', 'HOTFIX_COT_CONVERSION_ATOMICA.sql')); }
});
test('guarda de seguridad: rechaza la huella del proyecto de producción y URLs inválidas, sin conectar', { skip: SKIP }, () => {
  assert.equal(HUELLA_PRODUCCION.length, 64);
  assert.notEqual(sha('aaaaaaaaaaaaaaaaaaaa'), HUELLA_PRODUCCION);
  /* se prueba la CLI con la URL de produccion: debe terminar en codigo 4 sin pedir clave */
  const REF_PROD = 'egjlrcokerffuoqwbxlh'; /* ref publico que ya va en el HTML publicado */
  assert.equal(sha(REF_PROD), HUELLA_PRODUCCION, 'la huella corresponde al proyecto de produccion');
  const p = spawnSync(process.execPath, [path.join(__dirname, 'ensayo-postgrest.cjs')], { input: `https://${REF_PROD}.supabase.co\n`, encoding: 'utf8', timeout: 20000 });
  assert.equal(p.status, 4); assert.match(p.stderr, /PRODUCCION/);
  const q = spawnSync(process.execPath, [path.join(__dirname, 'ensayo-postgrest.cjs')], { input: `http://localhost:3000\n`, encoding: 'utf8', timeout: 20000 });
  assert.equal(q.status, 2);
});
