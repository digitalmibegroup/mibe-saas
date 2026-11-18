'use strict';
/* Caja, Reportes y Cartera frente a las ventas creadas por la CONVERSION atomica (sin abrir caja remota: PostgreSQL TEMPORAL).
   Ejecuta el codigo REAL del dashboard (extraido del HTML): obtenerMovimientosTurno + calcularCierreEsperado (Caja),
   cargarCarteraCompletaSB + diagnosticarCartera (Cartera) y las consultas/agregados del Reporte de ventas, con ventas de contado
   (efectivo y transferencia), credito sin abono y credito con abono. Datos ficticios. */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { disponible, iniciar, prepararBase, RAIZ } = require('./pg-temporal.cjs');
const { crearFetch } = require('./postgrest-shim.cjs');

const HTML = fs.readFileSync(path.join(RAIZ, 'dashboard_lacava.html'), 'utf8');
const entre = (ini, fin) => { const a = HTML.indexOf(ini), b = HTML.indexOf(fin, a); assert.ok(a >= 0 && b >= 0, ini); return HTML.slice(a, b); };
const CONV = [
  entre('/* HOTFIX COTIZACIONES — alta compartida', '/* ===== HOTFIX COTIZACIONES: FIN alta compartida de clientes ===== */') + '/* ===== HOTFIX COTIZACIONES: FIN alta compartida de clientes ===== */',
  entre('/* ===== HOTFIX COTIZACIONES: cliente de la cotizacion =====', '/* ===== HOTFIX COTIZACIONES: FIN cliente de la cotizacion ===== */') + '/* ===== HOTFIX COTIZACIONES: FIN cliente de la cotizacion ===== */',
  entre('/* ===== HOTFIX COTIZACIONES: CONVERSION EN VENTA — INICIO', '/* ===== HOTFIX COTIZACIONES: CONVERSION EN VENTA — FIN ===== */') + '/* ===== HOTFIX COTIZACIONES: CONVERSION EN VENTA — FIN ===== */'
].join('\n');
const CAJA = entre('var DESTINO_FINANCIERO_POR_MEDIO', '\nfunction renderCajaBtn');
const CARTERA = entre('var CARTERA_SB = [];', '/* Lectura FRESCA desde Supabase de cartera + venta + TODOS sus abonos.');

const ANA = '11111111-1111-4111-8111-111111111111', VER = '2026-11-16T10:00:00.123456+00:00';
const cot = (n, items, total) => `('c0c0c0c0-0000-4000-8000-00000000000${n}','lacava',${n},${n},'Ana Pérez','3001112233','aprobada','${items}',${total},now(),'${VER}')`;
const ron = (q) => `[{"prod_id":"ron","nombre":"Ron 750","cantidad":${q},"precio_unitario":80000,"precio_total":${80000 * q},"tipo":"und","_precioBase":80000,"descItem":0}]`;
const SEMILLA = `
SET session_replication_role = replica;
TRUNCATE cotizacion_conversiones, cartera_abonos, cartera, detalle_ventas, ventas, cotizaciones, clientes_frecuentes, inventario CASCADE;
CREATE TABLE IF NOT EXISTS gastos (id uuid DEFAULT gen_random_uuid() PRIMARY KEY, id_licencia text, categoria text, valor numeric, medio_pago text, created_at timestamptz DEFAULT now()); GRANT ALL ON gastos TO anon;
INSERT INTO inventario (id,nombre,categoria,precio_venta,stock,uds_sueltas,uds_empaque,id_licencia) VALUES ('ron','Ron 750','Licores',80000,50,0,1,'lacava');
INSERT INTO clientes_frecuentes (id,nombre,whatsapp,direccion,detalle,id_licencia) VALUES ('${ANA}','Ana Pérez','3001112233','Calle 1 # 2-3','Apto 101','lacava');
INSERT INTO cotizaciones (id,id_licencia,numero_local,numero,cliente_nombre,cliente_whatsapp,estado,items,total,fecha_creacion,updated_at) VALUES
 ${cot(1, ron(2), 160000)}, ${cot(2, ron(1), 80000)}, ${cot(3, ron(2), 160000)}, ${cot(4, ron(3), 240000)};
RESET session_replication_role;`;

let pg = null;
const SKIP = !disponible() && 'PostgreSQL portable no disponible';
const uno = q => pg.sql(q).out;
function contexto() {
  const f = crearFetch(pg);
  const ctx = {
    SB: 'https://simulado.local', SK: 'k', CID: 'lacava', fetch: f, Response, URL, TextEncoder, crypto: globalThis.crypto, AbortController,
    H: { apikey: 'k', Authorization: 'Bearer k', 'Content-Type': 'application/json', Prefer: 'return=representation' },
    setTimeout, clearTimeout, console: { log() {}, warn() {}, error() {} }, toast() {}, clisDB: [], fmt: n => '$' + Math.round(n),
    document: { addEventListener() {}, getElementById() { return null; } }
  };
  vm.createContext(ctx); vm.runInContext(CONV + '\n' + CAJA + '\n' + CARTERA, ctx);
  return ctx;
}
async function convertir(ctx, n, pagoInput) {
  const id = `c0c0c0c0-0000-4000-8000-00000000000${n}`;
  const s = Object.assign({ sbId: id }, await ctx.prepararConversionCot(id));
  assert.equal(s.fase, 'resumen', s.msg);
  const vp = ctx.validarPagoConvCot(pagoInput, s.plan.total, s.cliSel); assert.ok(vp.ok, vp.errores.join(';'));
  const p = ctx.parametrosConvCot(s, pagoInput, s.cliSel ? { id: s.cliSel.id } : null); p.p_op_clave = ctx.nuevaClaveConvCot();
  const r = await ctx.llamarConversionAtomicaCot(p); assert.equal(r.estado, 'completada', r.msg);
}

before(() => { if (SKIP) return; pg = iniciar(); prepararBase(pg); assert.ok(pg.sql(SEMILLA).ok); });
after(() => { if (pg) pg.detener(); });

test('las 4 conversiones (contado efectivo, transferencia, credito sin abono, credito con abono)', { skip: SKIP }, async () => {
  const ctx = contexto();
  await convertir(ctx, 1, { tipo: 'efectivo' });                                                         /* 160 000 efectivo */
  await convertir(ctx, 2, { tipo: 'transferencia', origen: 'Nequi' });                                   /*  80 000 banco    */
  await convertir(ctx, 3, { tipo: 'credito', plazo: '15', abono: '' });                                  /* 160 000 credito, sin abono */
  await convertir(ctx, 4, { tipo: 'credito', plazo: '30', abono: '50000', medioAbono: 'transferencia', origenAbono: 'Llave Bancolombia' }); /* 240 000, abono 50 000 banco */
  assert.equal(uno(`SELECT count(*) FROM ventas`), '4'); assert.equal(uno(`SELECT count(*) FROM cartera`), '2'); assert.equal(uno(`SELECT count(*) FROM cartera_abonos`), '1');
});

test('CAJA: el cierre esperado cuenta cada peso una sola vez (contado, credito sin abono y con abono)', { skip: SKIP }, async () => {
  const ctx = contexto();
  const desde = new Date(Date.now() - 3600e3).toISOString();
  const mov = await ctx.obtenerMovimientosTurno(desde);
  assert.equal(mov.ventas.length, 4); assert.equal(mov.abonos.length, 1);
  const c = ctx.calcularCierreEsperado(100000, 20000, mov);
  assert.equal(c.efectivoEsperado, 100000 + 160000, 'efectivo: base + contado en efectivo (el credito sin abono no suma)');
  assert.equal(c.bancoEsperado, 20000 + 80000 + 50000, 'banco: base + transferencia + abono inicial (una sola vez: el espejo evita duplicarlo)');
  assert.equal(c.carteraPendiente, 160000 + 190000, 'cartera pendiente: 160 000 sin abono + (240 000 - 50 000)');
  assert.equal(c.detalle.desconocidos, 0, 'ningun medio desconocido');
  assert.equal(c.detalle.numVentas, 4); assert.equal(c.detalle.numAbonos, 1);
  assert.equal(c.detalle.ventasEf, 160000); assert.equal(c.detalle.ventasBa, 80000); assert.equal(c.detalle.abonosBa, 50000); assert.equal(c.detalle.abonosEf, 0);
});

test('CARTERA: las carteras creadas por la conversion se leen como coherentes (no "pendiente de conciliacion")', { skip: SKIP }, async () => {
  const ctx = contexto();
  assert.equal(await ctx.cargarCarteraCompletaSB(), true);
  assert.equal(ctx.CARTERA_SB.length, 2);
  const g = async u => (await (await ctx.fetch(ctx.SB + '/rest/v1/' + u)).json());
  for (const c of ctx.CARTERA_SB) {
    const [row] = await g('cartera?id=eq.' + c._sbId + '&select=*');
    const [venta] = await g('ventas?id=eq.' + row.venta_id + '&select=*');
    const abonos = await g('cartera_abonos?cartera_id=eq.' + c._sbId + '&select=*');
    const d = ctx.diagnosticarCartera(row, venta, abonos);
    assert.equal(d.estado, 'ok', 'cartera #' + row.numero_venta + ': ' + d.motivo);
  }
  const conAbono = ctx.CARTERA_SB.find(c => c.total === 240000);
  assert.equal(conAbono.saldo_pendiente, 190000); assert.equal(conAbono.abonos_hist.length, 1); assert.equal(conAbono.abonos_hist[0].monto, 50000);
  assert.equal(ctx.CARTERA_SB.find(c => c.total === 160000).abonos_hist.length, 0);
});

test('CARTERA: un abono posterior sobre la cartera creada por la conversion se acepta (RPC de produccion)', { skip: SKIP }, async () => {
  const ctx = contexto();
  await ctx.cargarCarteraCompletaSB();
  const c = ctx.CARTERA_SB.find(x => x.total === 240000);
  const x = pg.sql(`SELECT public.registrar_abono_cartera_atomico('${c._sbId}'::uuid, 'lacava', 40000, now(), 'efectivo')`);
  assert.ok(x.ok, x.err);
  assert.equal(uno(`SELECT saldo_pendiente FROM cartera WHERE id='${c._sbId}'`).replace(/\.0+$/, ''), '150000');
  await ctx.cargarCarteraCompletaSB();
  const [row] = (await (await ctx.fetch(ctx.SB + '/rest/v1/cartera?id=eq.' + c._sbId + '&select=*')).json());
  const [venta] = (await (await ctx.fetch(ctx.SB + '/rest/v1/ventas?id=eq.' + row.venta_id + '&select=*')).json());
  const abonos = await (await ctx.fetch(ctx.SB + '/rest/v1/cartera_abonos?cartera_id=eq.' + c._sbId + '&select=*')).json();
  assert.equal(ctx.diagnosticarCartera(row, venta, abonos).estado, 'ok');
  /* y la Caja del turno recoge ese abono en efectivo, sin duplicar el inicial */
  const mov = await ctx.obtenerMovimientosTurno(new Date(Date.now() - 3600e3).toISOString());
  const cc = ctx.calcularCierreEsperado(0, 0, mov);
  assert.equal(cc.efectivoEsperado, 160000 + 40000); assert.equal(cc.bancoEsperado, 80000 + 50000); assert.equal(cc.carteraPendiente, 160000 + 150000);
});

test('REPORTE DE VENTAS: las columnas que consume existen y los agregados salen bien', { skip: SKIP }, async () => {
  const ctx = contexto();
  const hoy = new Date().toISOString().slice(0, 10);
  /* misma consulta que el reporte de ventas del dashboard (linea "repVentasContent") */
  const r = await ctx.fetch(ctx.SB + '/rest/v1/ventas?id_cliente=eq.lacava&created_at=gte.' + hoy + 'T00:00:00-05:00&created_at=lte.' + hoy + 'T23:59:59-05:00&select=id,total,metodo_pago,created_at,cliente_nombre,estado,numero_venta&order=created_at.asc&limit=1000');
  assert.equal(r.status, 200);
  const ventas = await r.json();
  assert.equal(ventas.length, 4);
  assert.ok(ventas.every(v => v.id && v.total != null && v.metodo_pago && v.created_at && v.cliente_nombre === 'Ana Pérez' && v.numero_venta > 0));
  const reales = ventas.filter(v => v.estado !== 'canje'), credito = ventas.filter(v => v.estado === 'credito');
  assert.equal(reales.reduce((s, v) => s + v.total, 0), 160000 + 80000 + 160000 + 240000);
  assert.equal(credito.length, 2); assert.equal(credito.reduce((s, v) => s + v.total, 0), 400000);
  const porMetodo = {}; reales.forEach(v => { porMetodo[v.metodo_pago] = (porMetodo[v.metodo_pago] || 0) + v.total; });
  assert.deepEqual(porMetodo, { efectivo: 320000, transferencia: 320000 });
  /* detalle para "Top productos": mismas columnas que el reporte */
  const ids = reales.map(v => v.id).join(',');
  const d = await (await ctx.fetch(ctx.SB + '/rest/v1/detalle_ventas?venta_id=in.(' + ids + ')&select=producto_nombre,cantidad,precio_unitario&limit=500')).json();
  assert.equal(d.length, 4); assert.equal(d.reduce((s, x) => s + x.cantidad, 0), 2 + 1 + 2 + 3);
  assert.ok(d.every(x => x.producto_nombre === 'Ron 750' && x.precio_unitario === 80000));
  /* las ventas de la conversion no son canje ni tienen domicilio: Caja y Reportes las tratan como cualquier venta */
  assert.equal(uno(`SELECT count(*) FROM ventas WHERE COALESCE(domicilio,0)<>0 OR estado='canje'`), '0');
});
