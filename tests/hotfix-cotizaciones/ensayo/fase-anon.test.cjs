'use strict';
/* Ensayo LOCAL de la fase anon: captura -> apertura minima -> guion anon por PostgREST (simulado como rol anon real de la base
   temporal) -> restauracion -> captura identica a la inicial. Base: v5 + H1 + variante del hotfix para staging (authenticated-only). */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), net = require('node:net');
const { crearProxy } = require('./servidor-ensayo-staging.cjs');
const { ejecutar } = require('./ensayo-staging-fase-anon.cjs');
const { crearFetch } = require('../pg/postgrest-shim.cjs');
const RAIZ = path.join(__dirname, '..', '..', '..');
const INTEGRACION = process.env.LACAVA_INTEGRACION || 'C:/Users/USUARIO/Proyectos - Claude code/La Cava licorera/mibe-saas-integracion-compras';
const SKIP = !fs.existsSync(INTEGRACION) && 'falta la copia de integracion (solo lectura)';
const libre = () => new Promise((r, j) => { const s = net.createServer(); s.on('error', j); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => r(p)); }); });
const SQL = n => path.join(RAIZ, n);
let B = null, proxy = null, base = null;
/* Administrador SIN superusuario que posee las tablas (como el rol postgres de Supabase) y solo tiene ADMIN sobre cotconv_ejecutor, sin SET ni INHERIT. */
const admin = ruta => B.psql(`SET ROLE supa_adm;\n\\i '${ruta.split('\\').join('/')}'`, null);
const captura = () => { const r = B.psql('', null, SQL('ANON_ENSAYO_STAGING_CAPTURA.sql')); assert.ok(r.ok, r.err); return r.out.split('\n').map(x => x.trim()).filter(x => x.startsWith('CAPT|')); };

before(async () => {
  if (SKIP) return;
  const { construir } = require('./base-h1.cjs'); B = await construir();
  const i = B.psql('', null, SQL('HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql')); assert.ok(i.ok, i.err);
  B.ok(`INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, uds_sueltas, uds_empaque, id_licencia) VALUES
    ('ens-cerveza6','Cerveza x6 (ENSAYO)','Ensayo',60000,40000,100,2,6,'lacava'),('ens-ron','Ron 750 (ENSAYO)','Ensayo',80000,50000,100,0,1,'lacava')`);
  B.ok(`CREATE ROLE supa_adm NOLOGIN CREATEROLE NOSUPERUSER; GRANT cotconv_ejecutor TO supa_adm WITH ADMIN OPTION, INHERIT FALSE, SET FALSE;`);
  for (const t of ['cotizaciones', 'clientes_frecuentes', 'inventario', 'ventas', 'detalle_ventas', 'cartera', 'cartera_abonos', 'licencias', 'cotizacion_conversiones']) B.ok('ALTER TABLE public.' + t + ' OWNER TO supa_adm');
  const shim = crearFetch(B);
  const upstream = (url, opts) => shim(url.replace(/^https:\/\/ca10112ba2\.invalid/, 'https://x'), Object.assign({}, opts, { rol: 'anon' }));
  const puerto = await libre();
  proxy = crearProxy({ puerto, base: 'https://ca10112ba2.invalid', fetch: upstream, credenciales: async () => ({ apikey: 'ANON', Authorization: 'Bearer ANON' }), sesion: () => ({ modo: 'solo anon (sin sesion)' }) });
  await new Promise(ok => proxy.servidor.listen(puerto, '127.0.0.1', ok));
  base = 'http://127.0.0.1:' + puerto;
});
after(() => { if (proxy) proxy.servidor.close(); if (B) B.detener(); });

test('antes de abrir: anon no puede nada y la guarda del guion se detiene', { skip: SKIP }, async () => {
  assert.ok(captura().length > 50, 'la captura tiene lineas');
  await assert.rejects(() => ejecutar({ base, log() {} }), /apertura temporal no esta activa/);
});

test('apertura minima -> guion anon completo -> restauracion exacta', { skip: SKIP, timeout: 600000 }, async () => {
  const antes = captura();
  const ab = admin(SQL('ANON_ENSAYO_STAGING_ABRIR.sql')); assert.ok(ab.ok, ab.err);
  const durante = captura();
  assert.notDeepEqual(durante, antes);
  assert.equal(durante.filter(l => /\|ens_anon_/.test(l)).length, 11);
  assert.ok(durante.some(l => /^CAPT\|funcion\|(public\.)?convertir_cotizacion_atomica.*anon=X/.test(l)), 'anon ejecuta la funcion durante la apertura');
  const otra = admin(SQL('ANON_ENSAYO_STAGING_ABRIR.sql')); assert.equal(otra.ok, false, 'una segunda apertura se rechaza'); assert.match(otra.err, /APERTURA/);
  /* H1 intacto durante la apertura */
  const h1 = l => l.filter(x => /^CAPT\|politica\|.*\|h1_/.test(x));
  assert.deepEqual(h1(durante), h1(antes));
  const lineas = [];
  const r = await ejecutar({ base, log: l => lineas.push(l) });
  const malas = r.resultados.filter(x => !x.ok);
  assert.equal(malas.length, 0, JSON.stringify(malas, null, 1) + '\n' + lineas.join('\n'));
  assert.equal(r.total, 29, 'comprobaciones: ' + r.total);
  assert.equal(r.inventario.ventas.length, 3); assert.equal(r.inventario.operaciones.length, 3); assert.equal(r.inventario.carteras.length, 1); assert.equal(r.inventario.abonos.length, 1);
  assert.equal(B.ok(`SELECT count(*) FROM cotizacion_conversiones`), '3');
  assert.equal(B.ok(`SELECT count(*) FROM ventas WHERE cliente_nombre NOT LIKE '%(ENSAYO)%'`), '0', B.ok(`SELECT string_agg(numero_venta||':'||COALESCE(cliente_nombre,'NULL'),' ; ') FROM ventas`));
  const rs = admin(SQL('ANON_ENSAYO_STAGING_RESTAURAR.sql')); assert.ok(rs.ok, rs.err);
  const despues = captura();
  assert.deepEqual(despues, antes, 'la captura tras restaurar es identica a la inicial');
  const rs2 = admin(SQL('ANON_ENSAYO_STAGING_RESTAURAR.sql')); assert.ok(rs2.ok, 'restaurar es idempotente');
  assert.deepEqual(captura(), antes);
  /* tras restaurar, anon vuelve a no poder nada */
  for (const q of ['SELECT * FROM cotizaciones LIMIT 1', 'SELECT * FROM cotizacion_conversiones LIMIT 1', `SELECT public.cotizacion_conversion_info('lacava','00000000-0000-4000-8000-000000000000')`]) {
    const x = B.psql(q, 'anon'); assert.equal(x.ok, false, q); assert.equal(x.codigo, '42501', q);
  }
});

test('la restauracion funciona aunque el guion falle a mitad (apertura -> fallo -> restaurar)', { skip: SKIP }, async () => {
  const antes = captura();
  assert.ok(admin(SQL('ANON_ENSAYO_STAGING_ABRIR.sql')).ok);
  await assert.rejects(() => ejecutar({ base: 'http://127.0.0.1:1', log() {} }));
  assert.ok(admin(SQL('ANON_ENSAYO_STAGING_RESTAURAR.sql')).ok);
  assert.deepEqual(captura(), antes);
});
