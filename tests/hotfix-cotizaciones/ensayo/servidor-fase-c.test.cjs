'use strict';
/* Ensayo LOCAL del servidor de ensayo y del guion de la fase C, contra una base v5 + H1 con la variante del hotfix instalada
   (PostgreSQL temporal, datos ficticios) y un "upstream" que emula PostgREST como authenticated con perfil. El ensayo real en
   staging (PostgREST de Supabase) confirma los codigos HTTP reales. */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), net = require('node:net');
const { crearProxy, validarDestino, HUELLA_STAGING, DECOY } = require('./servidor-ensayo-staging.cjs');
const { ejecutar } = require('./ensayo-staging-fase-c.cjs');
const { crearFetch } = require('../pg/postgrest-shim.cjs');
const RAIZ = path.join(__dirname, '..', '..', '..');
const INTEGRACION = process.env.LACAVA_INTEGRACION || 'C:/Users/USUARIO/Proyectos - Claude code/La Cava licorera/mibe-saas-integracion-compras';
const SKIP = !fs.existsSync(INTEGRACION) && 'falta la copia de integracion (solo lectura)';
const libre = () => new Promise((r, j) => { const s = net.createServer(); s.on('error', j); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => r(p)); }); });

let B = null, srv = null, base = null, puerto = null, proxy = null;
before(async () => {
  if (SKIP) return;
  const { construir } = require('./base-h1.cjs'); B = await construir();
  const i = B.psql('', null, path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql')); assert.ok(i.ok, i.err);
  const shim = crearFetch(B);
  /* upstream falso: elige el rol segun la credencial que inyecta el proxy (JWT del usuario ficticio o solo la clave anon) */
  const upstream = (url, opts) => shim(url.replace(/^https:\/\/ca10112ba2\.invalid/, 'https://x'), Object.assign({}, opts, { rol: opts.headers.Authorization === 'Bearer JWT-FICTICIO' ? 'authenticated' : 'anon' }));
  puerto = await libre();
  proxy = crearProxy({ puerto, base: 'https://ca10112ba2.invalid', fetch: upstream, credenciales: async (sin) => sin ? { apikey: 'ANON', Authorization: 'Bearer ANON' } : { apikey: 'ANON', Authorization: 'Bearer JWT-FICTICIO' }, sesion: () => ({ licencia: 'lacava' }) });
  await new Promise(ok => proxy.servidor.listen(puerto, '127.0.0.1', ok));
  base = 'http://127.0.0.1:' + puerto;
});
after(() => { if (proxy) proxy.servidor.close(); if (B) B.detener(); });

test('guardas de destino: solo el staging; produccion y otros proyectos se rechazan', () => {
  assert.match(validarDestino('https://egjlrcokerffuoqwbxlh.supabase.co'), /PRODUCCION/);
  assert.match(validarDestino('https://aaaaaaaaaaaaaaaaaaaa.supabase.co'), /NO es el staging/);
  assert.match(validarDestino('http://localhost:3000'), /debe ser https/);
  assert.equal(HUELLA_STAGING.length, 10);
});
test('el dashboard servido no contiene URL de supabase.co ni claves de staging y apunta al servidor local', { skip: SKIP }, async () => {
  const h = await (await fetch(base + '/')).text();
  assert.ok(h.includes("var SB='" + base + "';"));
  assert.doesNotMatch(h.replace(/https:\/\/(?:fonts|wa)\.[a-z.]+/g, ''), /supabase\.co/);
  assert.doesNotMatch(h, /JWT-FICTICIO/);
});
test('el servidor bloquea escrituras fuera del ensayo y deja pasar las del ensayo', { skip: SKIP }, async () => {
  const w = (m, r, b) => fetch(base + '/rest/v1/' + r, { method: m, headers: { 'content-type': 'application/json', Prefer: 'return=representation' }, body: b === undefined ? undefined : JSON.stringify(b) });
  assert.equal((await w('DELETE', 'ventas?id=eq.x')).status, 403);
  assert.equal((await w('POST', 'ventas', { total: 1 })).status, 403);
  assert.equal((await w('POST', 'inventario', [{ id: 'real-uno', nombre: 'x' }])).status, 403, 'productos reales protegidos');
  assert.equal((await w('PATCH', 'inventario?id=eq.real-uno', { stock: 0 })).status, 403);
  assert.equal((await w('PATCH', 'cotizaciones?id=eq.11111111-1111-4111-8111-111111111111', { estado: 'x' })).status, 403, 'solo registros creados por el ensayo');
  assert.equal((await w('POST', 'rpc/convertir_cotizacion_atomica', { p_cotizacion_id: '11111111-1111-4111-8111-111111111111' })).status, 403, 'solo cotizaciones del ensayo');
  assert.equal((await w('POST', 'rpc/otra_funcion', {})).status, 403);
  const motivos = (await (await fetch(base + '/__log')).json()).filter(x => x.bloqueado);
  assert.ok(motivos.length >= 6);
});
test('FASE C completa contra la base local v5 + H1 (como authenticated): todas las comprobaciones correctas', { skip: SKIP }, async () => {
  const lineas = [];
  const r = await ejecutar({ base, log: l => lineas.push(l) });
  const malas = r.resultados.filter(x => !x.ok);
  assert.equal(malas.length, 0, JSON.stringify(malas, null, 1));
  assert.ok(r.total >= 38, 'comprobaciones: ' + r.total);
  assert.equal(r.inventario.operaciones.length, 7); assert.equal(r.inventario.ventas.length, 7); assert.equal(r.inventario.cotizaciones.length, 10);
  assert.equal(r.inventario.carteras.length, 2); assert.equal(r.inventario.abonos.length, 1);
  assert.equal(B.ok(`SELECT count(*) FROM cotizacion_conversiones`), String(r.inventario.operaciones.length), 'registro = operaciones confirmadas');
  /* nada ajeno al ensayo: los productos reales no cambiaron */
  assert.equal(B.ok(`SELECT stock||'/'||uds_sueltas FROM inventario WHERE id='real-uno'`), '10/2');
  assert.equal(B.ok(`SELECT count(*) FROM ventas WHERE cliente_nombre NOT LIKE '%(ENSAYO)%'`), '0');
});
test('segunda ejecución: reutiliza los datos de ensayo y no los sobrescribe; un id ajeno detiene el guion', { skip: SKIP }, async () => {
  const r = await ejecutar({ base, log() {} });
  assert.equal(r.resultados.filter(x => !x.ok).length, 0);
  assert.ok(r.inventario.productos.every(p => p.creado_en_esta_ejecucion === false));
  B.ok(`UPDATE inventario SET nombre='Producto real sin marca' WHERE id='ens-ron'`);
  await assert.rejects(() => ejecutar({ base, log() {} }), /NO es de ensayo/);
  B.ok(`UPDATE inventario SET nombre='Ron 750 (ENSAYO)' WHERE id='ens-ron'`);
});
test('fallas simuladas de red: la respuesta perdida se reintenta con la misma clave y no duplica', { skip: SKIP }, async () => {
  const api = (m, r, b, h) => fetch(base + '/rest/v1/' + r, { method: m, headers: Object.assign({ 'content-type': 'application/json', Prefer: 'return=representation' }, h), body: b === undefined ? undefined : JSON.stringify(b) });
  const cot = await (await api('POST', 'cotizaciones', { id: '5e5e5e5e-0000-4000-8000-0000000000f1', id_licencia: 'lacava', numero_local: Date.now() + 99, numero: 1, cliente_nombre: 'Cliente Ficticio (ENSAYO)', estado: 'aprobada', items: [{ prod_id: 'ens-ron', nombre: 'Ron (ENSAYO)', cantidad: 1, precio_unitario: 80000, precio_total: 80000, tipo: 'und' }], total: 80000, fecha_creacion: new Date().toISOString() })).json();
  const params = { p_id_licencia: 'lacava', p_cotizacion_id: cot[0].id, p_op_clave: 'conv-' + require('node:crypto').randomUUID(), p_cotizacion_updated_at: cot[0].updated_at, p_pago: { tipo: 'efectivo', total_esperado: 80000 }, p_cliente_id: '5e5e5e5e-0000-4000-8000-0000000000e1', p_entrega: {} };
  await fetch(base + '/__falla?modo=perdida&n=1');
  await assert.rejects(() => api('POST', 'rpc/convertir_cotizacion_atomica', params), /fetch failed/);
  assert.equal(B.ok(`SELECT count(*) FROM ventas WHERE cotizacion_id='${cot[0].id}'`), '1', 'la venta se aplicó aunque la respuesta se perdió');
  const r2 = await api('POST', 'rpc/convertir_cotizacion_atomica', params); const j2 = await r2.json();
  assert.equal(r2.status, 200); assert.equal(j2.repetida, true); assert.equal(B.ok(`SELECT count(*) FROM ventas WHERE cotizacion_id='${cot[0].id}'`), '1');
  await fetch(base + '/__falla?modo=antes&n=1');
  await assert.rejects(() => api('POST', 'rpc/convertir_cotizacion_atomica', Object.assign({}, params, { p_op_clave: 'conv-' + require('node:crypto').randomUUID() })), /fetch failed/);
  assert.equal(B.ok(`SELECT count(*) FROM ventas WHERE cotizacion_id='${cot[0].id}'`), '1', 'la solicitud perdida antes de enviarse no escribió nada');
  const log = await (await fetch(base + '/__log')).json();
  assert.ok(log.some(x => x.simulado && /perdida despues/.test(x.simulado)) && log.some(x => x.simulado && /antes de enviarse/.test(x.simulado)));
  assert.equal(JSON.stringify(log).includes('JWT-FICTICIO'), false, 'el registro no contiene credenciales');
});
