'use strict';
/* Punta a punta: el codigo REAL del dashboard (extraido del HTML) contra la funcion REAL
   en un PostgreSQL TEMPORAL, a traves de un adaptador con forma de PostgREST (rol anon).
   Datos ficticios. Sin red externa. */
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { disponible, iniciar, prepararBase, RAIZ } = require('./pg-temporal.cjs');
const { crearFetch } = require('./postgrest-shim.cjs');

const HTML = fs.readFileSync(path.join(RAIZ, 'dashboard_lacava.html'), 'utf8');
const entre = (ini, fin) => { const a = HTML.indexOf(ini), b = HTML.indexOf(fin, a); assert.ok(a >= 0 && b >= 0, ini); return HTML.slice(a, b + fin.length); };
const CODIGO = [
  entre('/* HOTFIX COTIZACIONES — alta compartida', '/* ===== HOTFIX COTIZACIONES: FIN alta compartida de clientes ===== */'),
  entre('/* ===== HOTFIX COTIZACIONES: cliente de la cotizacion =====', '/* ===== HOTFIX COTIZACIONES: FIN cliente de la cotizacion ===== */'),
  entre('/* ===== HOTFIX COTIZACIONES: CONVERSION EN VENTA — INICIO', '/* ===== HOTFIX COTIZACIONES: CONVERSION EN VENTA — FIN ===== */')
].join('\n');

const COT = 'c0c0c0c0-0000-4000-8000-000000000001', COT2 = 'c0c0c0c0-0000-4000-8000-000000000002', ANA = '11111111-1111-4111-8111-111111111111';
const VER = '2026-11-16T10:00:00.123456+00:00';
const SEMILLA = `
SET session_replication_role = replica;
TRUNCATE cotizacion_conversiones, cartera_abonos, cartera, detalle_ventas, ventas, cotizaciones, clientes_frecuentes, inventario CASCADE;
INSERT INTO inventario (id,nombre,categoria,precio_venta,stock,uds_sueltas,uds_empaque,id_licencia) VALUES
 ('cerveza6','Cerveza x6','Cervezas',60000,10,2,6,'lacava'),('ron','Ron 750','Licores',80000,5,0,1,'lacava');
INSERT INTO clientes_frecuentes (id,nombre,whatsapp,direccion,detalle,id_licencia) VALUES ('${ANA}','Ana Pérez','3001112233','Calle 1 # 2-3','Apto 101','lacava');
INSERT INTO cotizaciones (id,id_licencia,numero_local,numero,cliente_nombre,cliente_whatsapp,estado,items,total,fecha_creacion,updated_at) VALUES
 ('${COT}','lacava',1,7,'Ana Pérez','3001112233','aprobada','[
   {"prod_id":"cerveza6","nombre":"Cerveza x6","cantidad":3,"precio_unitario":10000,"precio_total":30000,"tipo":"und","_precioBase":10000,"descItem":0},
   {"prod_id":"cerveza6","nombre":"Cerveza x6 (Sixpack)","cantidad":1,"precio_unitario":55000,"precio_total":55000,"tipo":"emp","_precioBase":60000,"descItem":5000},
   {"prod_id":"ron","nombre":"Ron 750","cantidad":2,"precio_unitario":75000,"precio_total":150000,"tipo":"und","_precioBase":80000,"descItem":5000}]',235000,now(),'${VER}'),
 ('${COT2}','lacava',2,8,'Ana Pérez','3001112233','aprobada','[
   {"prod_id":"ron","nombre":"Ron 750","cantidad":1,"precio_unitario":80000,"precio_total":80000,"tipo":"und","_precioBase":80000,"descItem":0}]',80000,now(),'${VER}');
RESET session_replication_role;`;

let pg = null;
const SKIP = !disponible() && 'PostgreSQL portable no disponible';
const uno = (q) => pg.sql(q).out;
const pool = (id) => Number(uno(`SELECT stock*uds_empaque+uds_sueltas FROM inventario WHERE id='${id}'`));
function contexto(opciones) {
  const f = crearFetch(pg, opciones);
  const ctx = {
    SB: 'https://simulado.local', SK: 'k', CID: 'lacava', fetch: f, Response, URL, TextEncoder, crypto: globalThis.crypto, AbortController,
    H: { apikey: 'k', Authorization: 'Bearer k', 'Content-Type': 'application/json', Prefer: 'return=representation' },
    setTimeout, clearTimeout, console: { log() {}, warn() {}, error() {} }, toast() {}, clisDB: [], fmt: n => '$' + Math.round(n),
    document: { addEventListener() {}, getElementById() { return null; } }
  };
  vm.createContext(ctx); vm.runInContext(CODIGO, ctx);
  ctx.__fetch = f;
  return ctx;
}
/* Simula lo que hace el modal: preparar (solo lectura), validar y armar los parametros. */
async function preparar(ctx, cot, pagoInput, ajustes) {
  const s = Object.assign({ sbId: cot || COT }, await ctx.prepararConversionCot(cot || COT));
  assert.equal(s.fase, 'resumen', s.msg); assert.ok(s.plan.ok, s.plan.errores.join(';'));
  Object.assign(s, ajustes || {});
  const vp = ctx.validarPagoConvCot(pagoInput, s.plan.total, s.cliSel);
  assert.ok(vp.ok, vp.errores.join(';'));
  const params = ctx.parametrosConvCot(s, pagoInput, s.cliSel ? { id: s.cliSel.id } : null);
  params.p_op_clave = ctx.nuevaClaveConvCot();
  return params;
}

before(() => { if (SKIP) return; pg = iniciar(); prepararBase(pg); });
after(() => { if (pg) pg.detener(); });
beforeEach(() => { if (pg) assert.ok(pg.sql(SEMILLA).ok); });

test('la preparación del resumen solo lee', { skip: SKIP }, async () => {
  const ctx = contexto();
  await preparar(ctx, COT, { tipo: 'efectivo' });
  assert.ok(ctx.__fetch.log.every(x => x.method === 'GET'));
  assert.equal(uno(`SELECT count(*) FROM ventas`), '0');
});
test('contado: el dashboard convierte con una sola llamada atómica', { skip: SKIP }, async () => {
  const ctx = contexto();
  const p = await preparar(ctx, COT, { tipo: 'efectivo' }, { dir: 'Cra 9 # 1-1', det: 'Torre 2' });
  const r = await ctx.llamarConversionAtomicaCot(p);
  assert.equal(r.estado, 'completada', r.msg);
  assert.equal(ctx.__fetch.log.filter(x => x.method !== 'GET').length, 1, 'una sola escritura: la RPC');
  assert.equal(uno(`SELECT direccion_entrega||'|'||detalle_entrega||'|'||metodo_pago FROM ventas`), 'Cra 9 # 1-1|Torre 2|efectivo');
  assert.equal(pool('cerveza6'), 53); assert.equal(pool('ron'), 3);
  assert.equal(uno(`SELECT count(*) FROM detalle_ventas`), '3');
  assert.equal(uno(`SELECT estado FROM cotizaciones WHERE id='${COT}'`), 'convertida');
});
test('transferencia, crédito sin abono y crédito con abono', { skip: SKIP }, async () => {
  for (const [pi, esperado] of [
    [{ tipo: 'transferencia', origen: 'Nequi' }, 'completada|transferencia|Origen: Nequi|0'],
    [{ tipo: 'credito', plazo: '15', abono: '' }, 'credito|efectivo||0'],
    [{ tipo: 'credito', plazo: '30', abono: '35000', medioAbono: 'transferencia', origenAbono: 'Llave Bancolombia' }, 'credito|transferencia|Origen: Llave Bancolombia|1']
  ]) {
    pg.sql(SEMILLA);
    const ctx = contexto();
    const r = await ctx.llamarConversionAtomicaCot(await preparar(ctx, COT, pi));
    assert.equal(r.estado, 'completada', r.msg);
    assert.equal(uno(`SELECT estado||'|'||metodo_pago||'|'||COALESCE(notas,'')||'|'||(SELECT count(*) FROM cartera_abonos) FROM ventas`), esperado);
  }
});
test('abono igual al total: contado, con puntos si no hay descuento (regla de la base)', { skip: SKIP }, async () => {
  const ctx = contexto();
  const r = await ctx.llamarConversionAtomicaCot(await preparar(ctx, COT2, { tipo: 'credito', plazo: '30', abono: '80000', medioAbono: 'efectivo' }));
  assert.equal(r.estado, 'completada'); assert.equal(r.resultado.estado, 'completada'); assert.equal(r.resultado.puntos_ganados, 100);
});
test('respuesta perdida: reintenta con la misma clave y obtiene la misma venta, sin duplicar', { skip: SKIP }, async () => {
  const ctx = contexto({ perderRespuestas: 1 });
  const r = await ctx.llamarConversionAtomicaCot(await preparar(ctx, COT, { tipo: 'credito', plazo: '30', abono: '35000', medioAbono: 'efectivo' }));
  assert.equal(r.estado, 'completada', r.msg); assert.equal(r.resultado.repetida, true);
  assert.equal(uno(`SELECT count(*) FROM ventas`), '1'); assert.equal(uno(`SELECT count(*) FROM cartera_abonos`), '1'); assert.equal(pool('cerveza6'), 53);
});
test('todas las respuestas perdidas: estado "sin confirmación" y "Reintentar" completa sin duplicar', { skip: SKIP }, async () => {
  const ctx = contexto({ perderRespuestas: 3 });
  const p = await preparar(ctx, COT, { tipo: 'efectivo' });
  const r = await ctx.llamarConversionAtomicaCot(p);
  assert.equal(r.estado, 'incierta'); assert.match(r.msg, /completa o no se hizo nada/);
  assert.equal(uno(`SELECT count(*) FROM ventas`), '1', 'en la base quedó completa (una sola vez)');
  const r2 = await ctx.llamarConversionAtomicaCot(p);
  assert.equal(r2.estado, 'completada'); assert.equal(r2.resultado.repetida, true);
  assert.equal(uno(`SELECT count(*) FROM ventas`), '1'); assert.equal(pool('cerveza6'), 53);
});
test('respuesta perdida ANTES de llegar a la base: el reintento la aplica una sola vez', { skip: SKIP }, async () => {
  const ctx = contexto();
  const real = ctx.fetch; let primera = true;
  ctx.fetch = async (u, o) => { if (o && o.method === 'POST' && primera) { primera = false; throw new TypeError('Failed to fetch (no enviado)'); } return real(u, o); };
  const r = await ctx.llamarConversionAtomicaCot(await preparar(ctx, COT, { tipo: 'efectivo' }));
  assert.equal(r.estado, 'completada'); assert.equal(r.resultado.repetida, false);
  assert.equal(uno(`SELECT count(*) FROM ventas`), '1');
});
test('dos pestañas confirman a la vez: una venta; la otra recibe un rechazo sin escribir nada', { skip: SKIP }, async () => {
  const a = contexto(), b = contexto();
  const [pa, pb] = [await preparar(a, COT, { tipo: 'efectivo' }), await preparar(b, COT, { tipo: 'transferencia', origen: 'Nequi' })];
  const [ra, rb] = await Promise.all([a.llamarConversionAtomicaCot(pa), b.llamarConversionAtomicaCot(pb)]);
  const est = [ra.estado, rb.estado].sort();
  assert.deepEqual(est, ['completada', 'rechazada']);
  const rech = ra.estado === 'rechazada' ? ra : rb;
  assert.ok(['CV011', 'CV050'].includes(rech.codigo), rech.codigo);
  assert.equal(uno(`SELECT count(*) FROM ventas`), '1'); assert.equal(pool('cerveza6'), 53);
});
test('la cotización cambió después del resumen: rechazo claro y nada escrito', { skip: SKIP }, async () => {
  const ctx = contexto();
  const p = await preparar(ctx, COT, { tipo: 'efectivo' });
  pg.sql(`UPDATE cotizaciones SET updated_at=now() WHERE id='${COT}'`);
  const r = await ctx.llamarConversionAtomicaCot(p);
  assert.equal(r.estado, 'rechazada'); assert.equal(r.codigo, 'CV012'); assert.match(r.msg, /cambió/);
  assert.equal(uno(`SELECT count(*) FROM ventas`), '0'); assert.equal(pool('cerveza6'), 62);
});
test('stock agotado entre el resumen y la confirmación: rechazo y nada descontado', { skip: SKIP }, async () => {
  const ctx = contexto();
  const p = await preparar(ctx, COT, { tipo: 'efectivo' });
  pg.sql(`UPDATE inventario SET stock=1 WHERE id='ron'`);
  const r = await ctx.llamarConversionAtomicaCot(p);
  assert.equal(r.estado, 'rechazada'); assert.equal(r.codigo, 'CV037'); assert.match(r.msg, /Stock insuficiente de Ron 750/);
  assert.equal(pool('cerveza6'), 62, 'la cerveza no se descontó'); assert.equal(uno(`SELECT count(*) FROM ventas`), '0');
});
test('clave reutilizada con otro pago: rechazo CV020', { skip: SKIP }, async () => {
  const ctx = contexto();
  const p = await preparar(ctx, COT, { tipo: 'efectivo' });
  assert.equal((await ctx.llamarConversionAtomicaCot(p)).estado, 'completada');
  const otro = JSON.parse(JSON.stringify(p)); otro.p_pago = { tipo: 'transferencia', origen: 'Nequi', total_esperado: 235000 };
  const r = await ctx.llamarConversionAtomicaCot(otro);
  assert.equal(r.estado, 'rechazada'); assert.equal(r.codigo, 'CV020');
});
test('sin la función instalada: se informa y no se escribe nada', { skip: SKIP }, async () => {
  pg.archivo(path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql'));
  try {
    const ctx = contexto();
    const r = await ctx.llamarConversionAtomicaCot(await preparar(ctx, COT, { tipo: 'efectivo' }));
    assert.equal(r.estado, 'rechazada'); assert.equal(r.codigo, 'SIN_FUNCION');
    assert.equal(uno(`SELECT count(*) FROM ventas`), '0'); assert.equal(pool('cerveza6'), 62);
  } finally { pg.archivo(path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA.sql')); }
});
test('conversión incompleta de la versión anterior: diagnóstico solo de lectura', { skip: SKIP }, async () => {
  pg.sql(`INSERT INTO ventas (id,id_cliente,cliente_nombre,total,subtotal,metodo_pago,estado,cotizacion_id) VALUES ('aaaaaaaa-0000-4000-8000-000000000001','lacava','Ana',235000,235000,'efectivo','completada','${COT}');
          UPDATE cotizaciones SET estado='convertida' WHERE id='${COT}';`);
  const ctx = contexto();
  const d = await ctx.diagnosticarConversionAnteriorCot(COT);
  assert.equal(d.estado, 'diagnostico'); assert.equal(d.diag.ventas.length, 1); assert.equal(d.diag.detalle, 0); assert.equal(d.diag.cartera, 0);
  assert.ok(ctx.__fetch.log.every(x => x.method === 'GET' || x.path.endsWith('/rpc/cotizacion_conversion_info')), 'solo lecturas (la RPC de información es de solo lectura)');
  assert.match(ctx.htmlDiagConvCot(d.diag), /No se repara automáticamente/);
  const v = [{ id: 'aaaaaaaa-0000-4000-8000-000000000001', cotizacion_id: COT }];
  await ctx.marcarVentasConversionIncompleta(v);
  assert.equal(v[0]._convIncompleta, true, 'Ventas la marca como incompleta');
});

/* ===== Registro de operaciones: lo que ve el usuario ===== */
test('operación cuya venta se eliminó: el dashboard informa que ya estaba registrada y no recrea nada', { skip: SKIP }, async () => {
  const ctx = contexto();
  const p = await preparar(ctx, COT, { tipo: 'efectivo' });
  const r1 = await ctx.llamarConversionAtomicaCot(p);
  assert.equal(r1.estado, 'completada', r1.msg);
  /* eliminarVenta() del dashboard: desvincula, borra detalle y venta, restaura stock */
  assert.ok(pg.sql(`UPDATE cotizaciones SET venta_id=NULL, updated_at=now() WHERE id='${COT}'; DELETE FROM detalle_ventas; DELETE FROM ventas;
                    UPDATE inventario SET stock=10, uds_sueltas=2 WHERE id='cerveza6'; UPDATE inventario SET stock=5 WHERE id='ron';`, { rol: 'anon' }).ok);
  const antes = uno(`SELECT md5(string_agg(x::text,'|' ORDER BY x::text)) FROM (SELECT ventas::text x FROM ventas UNION ALL SELECT inventario::text FROM inventario) z`);
  const r2 = await ctx.llamarConversionAtomicaCot(p);
  assert.equal(r2.estado, 'rechazada'); assert.equal(r2.codigo, 'CV022'); assert.match(r2.msg, /su venta fue eliminada/);
  assert.equal(uno(`SELECT md5(string_agg(x::text,'|' ORDER BY x::text)) FROM (SELECT ventas::text x FROM ventas UNION ALL SELECT inventario::text FROM inventario) z`), antes);
  const d = await ctx.diagnosticarConversionAnteriorCot(COT);
  assert.equal(d.estado, 'diagnostico'); assert.equal(d.diag.operaciones.length, 1); assert.equal(d.diag.operaciones[0].venta_existe, false);
  const html = ctx.htmlDiagConvCot(d.diag);
  assert.match(html, /figura como convertida, pero no tiene venta vinculada/); assert.match(html, /NO se recrea ni se descuenta de nuevo/);
  assert.ok(ctx.__fetch.log.filter(x => x.method !== 'GET').every(x => /\/rpc\//.test(x.path)), 'solo llamadas RPC de lectura/conversión');
});
test('el dashboard ya no tiene acceso directo al registro: su lectura directa es rechazada', { skip: SKIP }, async () => {
  const ctx = contexto();
  assert.equal((await ctx.llamarConversionAtomicaCot(await preparar(ctx, COT, { tipo: 'efectivo' }))).estado, 'completada');
  const r = pg.sql(`SELECT count(*) FROM public.cotizacion_conversiones`, { rol: 'anon' });
  assert.equal(r.codigo, '42501');
});
