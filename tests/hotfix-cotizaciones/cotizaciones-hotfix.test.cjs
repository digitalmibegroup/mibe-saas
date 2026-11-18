'use strict';
/* Pruebas locales del hotfix de cotizaciones. Ejecutan el codigo REAL extraido de
   dashboard_lacava.html contra una base simulada en memoria (mock-postgrest.cjs) con
   las restricciones de produccion. No se conectan a Supabase ni a ninguna red. */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const { crearBase } = require('./mock-postgrest.cjs');

const RAIZ = path.join(__dirname, '..', '..');
/* "Version publicada" = el commit de produccion anterior al hotfix (inmutable). Se puede cambiar con LACAVA_REV_PUBLICADA. */
const REV_PUBLICADA = process.env.LACAVA_REV_PUBLICADA || 'eacde3b';
const hayRev = () => { try { execFileSync('git', ['cat-file', '-e', REV_PUBLICADA + '^{commit}'], { cwd: RAIZ, stdio: 'ignore' }); return true; } catch (e) { return false; } };
const HTML = fs.readFileSync(path.join(RAIZ, 'dashboard_lacava.html'), 'utf8');
function entre(src, ini, fin) {
  const a = src.indexOf(ini); assert.ok(a >= 0, 'falta inicio: ' + ini);
  const b = src.indexOf(fin, a); assert.ok(b >= 0, 'falta fin: ' + fin);
  return src.slice(a, b + fin.length);
}
const CODIGO = [
  entre(HTML, 'async function upsertCli(', '/* HOTFIX COTIZACIONES — alta compartida').replace(/\/\* HOTFIX COTIZACIONES — alta compartida$/, ''),
  entre(HTML, '/* HOTFIX COTIZACIONES — alta compartida', '/* ===== HOTFIX COTIZACIONES: FIN alta compartida de clientes ===== */'),
  entre(HTML, '/* ===== HOTFIX COTIZACIONES: cliente de la cotizacion =====', '/* ===== HOTFIX COTIZACIONES: FIN cliente de la cotizacion ===== */'),
  entre(HTML, '/* ===== HOTFIX COTIZACIONES: CONVERSION EN VENTA — INICIO', '/* ===== HOTFIX COTIZACIONES: CONVERSION EN VENTA — FIN ===== */')
].join('\n');

const COT = 'c0c0c0c0-0000-4000-8000-000000000001';
const ANA = '11111111-1111-4111-8111-111111111111';
function semilla() {
  return {
    inventario: [
      { id: 'cerveza6', nombre: 'Cerveza x6', categoria: 'Cervezas', precio_venta: 60000, stock: 10, uds_sueltas: 2, uds_empaque: 6, id_licencia: 'lacava' },
      { id: 'ron', nombre: 'Ron 750', categoria: 'Licores', precio_venta: 80000, stock: 5, uds_sueltas: 0, uds_empaque: 1, id_licencia: 'lacava' }
    ],
    clientes_frecuentes: [{ id: ANA, nombre: 'Ana Pérez', whatsapp: '3001112233', direccion: 'Calle 1 # 2-3', detalle: 'Apto 101', puntos: 0, total_compras: 0, num_pedidos: 0 }],
    cotizaciones: [{
      id: COT, id_licencia: 'lacava', numero_local: 1, numero: 7, cliente_nombre: 'Ana Pérez', cliente_whatsapp: '3001112233', estado: 'aprobada',
      items: [
        { _key: 'cerveza6_und', prod_id: 'cerveza6', nombre: 'Cerveza x6', cantidad: 3, precio_unitario: 10000, precio_total: 30000, tipo: 'und', _precioBase: 10000, descItem: 0 },
        { _key: 'cerveza6_emp', prod_id: 'cerveza6', nombre: 'Cerveza x6 (Sixpack)', cantidad: 1, precio_unitario: 55000, precio_total: 55000, tipo: 'emp', _precioBase: 60000, descItem: 5000 },
        { _key: 'ron_und', prod_id: 'ron', nombre: 'Ron 750', cantidad: 2, precio_unitario: 75000, precio_total: 150000, tipo: 'und', _precioBase: 80000, descItem: 5000 }
      ],
      total: 235000, fecha_creacion: '2026-11-15T10:00:00.000000+00:00', updated_at: '2026-11-16T10:00:00.123456+00:00'
    }]
  };
}
/* Pool inicial cerveza: 10*6+2 = 62 und. La cotizacion vende 3 und + 1 sixpack = 9 und -> 53 (8 cajas + 5 sueltas). Ron: 5 -> 3. */
const POOL_CERVEZA_INICIAL = 62, POOL_CERVEZA_FINAL = 53, RON_FINAL = 3;
function poolCerveza(base) { const p = base.T.inventario.find(x => x.id === 'cerveza6'); return p.stock * p.uds_empaque + p.uds_sueltas; }
function stockRon(base) { return base.T.inventario.find(x => x.id === 'ron').stock; }

function contexto(base, extra) {
  const ctx = {
    SB: 'https://simulado.supabase.local', SK: 'clave-simulada', CID: 'lacava',
    H: { apikey: 'clave-simulada', Authorization: 'Bearer clave-simulada', 'Content-Type': 'application/json', Prefer: 'return=representation' },
    fetch: base.fetch, Response, URL, TextEncoder, crypto: globalThis.crypto, AbortController,
    setTimeout, clearTimeout, console: { log() {}, warn() {}, error() {} },
    toast() {}, clisDB: [], sincronizarInvLocal() {}, PUNTOS_MIN_COMPRA: 50000, PUNTOS_RATIO: 800,
    document: { addEventListener() {}, getElementById() { return null; } }
  };
  Object.assign(ctx, extra || {});
  vm.createContext(ctx);
  vm.runInContext(CODIGO, ctx, { filename: 'hotfix-cotizaciones.js' });

  return ctx;
}
const plano = x => JSON.parse(JSON.stringify(x));
/* ============ 1. CLIENTES ============ */
test('la versión publicada fallaba al crear clientes por es_mayorista (reproducción)', { skip: !hayRev() && 'falta el commit de la version publicada (' + REV_PUBLICADA + ') en este clon' }, async () => {
  const viejo = execFileSync('git', ['show', REV_PUBLICADA + ':dashboard_lacava.html'], { cwd: RAIZ, encoding: 'utf8', maxBuffer: 1 << 26 });
  const fuente = entre(viejo, 'async function crearClienteNuevo(', "return{ok:false,motivo:'error'};}\n}");
  const base = crearBase(semilla());
  const ctx = { SB: 'https://simulado.supabase.local', SK: 'k', CID: 'lacava', H: {}, fetch: base.fetch, clisDB: [], console: { warn() {} }, encodeURIComponent };
  vm.createContext(ctx); vm.runInContext(fuente, ctx);
  const r = await ctx.crearClienteNuevo('Luis Gómez', '3109998877', 'Cra 5', '');
  assert.equal(r.ok, false, 'con la columna inexistente el alta falla');
  assert.equal(base.T.clientes_frecuentes.length, 1, 'no se creó nada');
});
test('alta de cliente: sin es_mayorista, con dirección y detalle, y queda en clisDB', async () => {
  const base = crearBase(semilla()); const ctx = contexto(base);
  const r = await ctx.crearClienteNuevo('  Luis   Gómez ', '3109998877', 'Cra 5 # 6-7', 'Casa azul');
  assert.equal(r.ok, true, JSON.stringify(plano(r)));
  const post = base.log.find(x => x.method === 'POST' && x.tabla === 'clientes_frecuentes');
  assert.ok(!('es_mayorista' in JSON.parse(post.body)));
  const nuevo = base.T.clientes_frecuentes.find(c => c.whatsapp === '3109998877');
  assert.equal(nuevo.direccion, 'Cra 5 # 6-7'); assert.equal(nuevo.detalle, 'Casa azul');
  assert.equal(ctx.clisDB.length, 1);
});
test('alta de cliente: un fallo de la búsqueda de duplicados NO se toma como "no existe"', async () => {
  const base = crearBase(semilla()); const ctx = contexto(base);
  base.fallas.push({ metodo: 'GET', tabla: 'clientes_frecuentes', n: 1, modo: 'http500_sin_aplicar' });
  const r = await ctx.crearClienteNuevo('Nuevo', '3000000000', '', '');
  assert.equal(r.ok, false); assert.equal(r.motivo, 'error_busqueda');
  assert.equal(base.log.filter(x => x.method === 'POST').length, 0, 'no intentó guardar');
  assert.match(ctx.mensajeAltaCliente(r), /No se pudo comprobar/);
});
test('alta de cliente: duplicado por WhatsApp y por nombre (mayúsculas y espacios)', async () => {
  const base = crearBase(semilla()); const ctx = contexto(base);
  const a = await ctx.crearClienteNuevo('Otra', '3001112233', '', '');
  assert.equal(a.motivo, 'duplicado'); assert.equal(a.cliente.id, ANA);
  const b = await ctx.crearClienteNuevo('  ana   PÉREZ ', '', '', '');
  assert.equal(b.motivo, 'duplicado');
  assert.equal(base.T.clientes_frecuentes.length, 1);
});
test('alta de cliente: los comodines del nombre no generan falsos duplicados', async () => {
  const base = crearBase(semilla()); const ctx = contexto(base);
  base.T.clientes_frecuentes.push({ id: crypto.randomUUID(), nombre: 'AnaXB', id_licencia: 'lacava' });
  const r = await ctx.crearClienteNuevo('Ana_B', '', '', '');
  assert.equal(r.ok, true, 'Ana_B no es AnaXB');
  const r2 = await ctx.crearClienteNuevo('Ana%', '', '', '');
  assert.equal(r2.ok, true);
});
test('alta de cliente: doble envío simultáneo crea una sola ficha', async () => {
  const base = crearBase(semilla()); const ctx = contexto(base);
  const [a, b] = await Promise.all([ctx.crearClienteNuevo('Doble', '3201234567', '', ''), ctx.crearClienteNuevo('Doble', '3201234567', '', '')]);
  assert.deepEqual([a.ok, b.ok].sort(), [false, true]);
  assert.equal([a, b].find(x => !x.ok).motivo, 'en_curso');
  assert.equal(base.T.clientes_frecuentes.filter(c => c.whatsapp === '3201234567').length, 1);
});
test('alta de cliente: respuesta perdida se informa como incierta y el reintento encuentra la ficha', async () => {
  const base = crearBase(semilla()); const ctx = contexto(base);
  base.fallas.push({ metodo: 'POST', tabla: 'clientes_frecuentes', n: 1, modo: 'perdida' });
  const r = await ctx.crearClienteNuevo('Perdido', '3150000000', '', '');
  assert.equal(r.motivo, 'error_guardado'); assert.equal(r.incierto, true);
  const r2 = await ctx.crearClienteNuevo('Perdido', '3150000000', '', '');
  assert.equal(r2.motivo, 'duplicado', 'no se crea una segunda ficha');
  assert.equal(base.T.clientes_frecuentes.filter(c => c.whatsapp === '3150000000').length, 1);
});
test('POS: el alta de cliente nuevo desde una venta ya no envía es_mayorista', async () => {
  const base = crearBase(semilla()); const ctx = contexto(base);
  ctx.document = { getElementById() { return { checked: true }; }, addEventListener() {} };
  await ctx.upsertCli('Cliente POS', '3140000000', 'Dir', 'Det', 50000, 10, null);
  const nuevo = base.T.clientes_frecuentes.find(c => c.whatsapp === '3140000000');
  assert.ok(nuevo, 'el cliente se creó');
  assert.equal(nuevo.puntos, 10); assert.equal(nuevo.num_pedidos, 1);
});

/* ============ 2. RESOLUCION DEL CLIENTE / DIRECCION ============ */
test('resolución del cliente: WhatsApp exacto, nombre único, ambigüedades y error', async () => {
  const base = crearBase(semilla()); const ctx = contexto(base);
  let r = await ctx.resolverClienteCot('Cualquier nombre', '3001112233');
  assert.equal(r.estado, 'vinculado'); assert.equal(r.cliente.direccion, 'Calle 1 # 2-3');
  r = await ctx.resolverClienteCot('ana pérez', '');
  assert.equal(r.estado, 'vinculado'); assert.equal(r.por, 'nombre');
  r = await ctx.resolverClienteCot('Ana Pérez', '3999999999');
  assert.equal(r.estado, 'ambiguo', 'mismo nombre pero otro WhatsApp: no se elige en silencio');
  base.T.clientes_frecuentes.push({ id: crypto.randomUUID(), nombre: 'ANA PÉREZ', id_licencia: 'lacava' });
  r = await ctx.resolverClienteCot('Ana Pérez', '');
  assert.equal(r.estado, 'ambiguo'); assert.equal(r.candidatos.length, 2);
  r = await ctx.resolverClienteCot('Nadie', '');
  assert.equal(r.estado, 'sin_registro');
  base.fallas.push({ metodo: 'GET', tabla: 'clientes_frecuentes', n: 1, modo: 'http500_sin_aplicar' });
  r = await ctx.resolverClienteCot('Ana Pérez', '3001112233');
  assert.equal(r.estado, 'error');
});
/* ============ 3. EMPAQUES ============ */
test('plan: und = unidad, emp = empaque con el uds_empaque vigente', () => {
  const ctx = contexto(crearBase());
  const inv = { p6: { id: 'p6', nombre: 'P6', stock: 10, uds_sueltas: 0, uds_empaque: 6 }, p1: { id: 'p1', nombre: 'P1', stock: 9, uds_sueltas: 0, uds_empaque: 1 } };
  const p = ctx.construirPlanConversionCot([
    { prod_id: 'p6', nombre: 'a', cantidad: 2, precio_unitario: 100, precio_total: 200, tipo: 'und' },
    { prod_id: 'p6', nombre: 'b', cantidad: 1, precio_unitario: 600, precio_total: 600, tipo: 'emp' },
    { prod_id: 'p1', nombre: 'c', cantidad: 3, precio_unitario: 10, precio_total: 30 }
  ], inv);
  assert.ok(p.ok, p.errores.join(';'));
  assert.deepEqual(plano(p.lineas.map(l => [l.es_unidad, l.uds_empaque, l.unidades])), [[true, 6, 2], [false, 6, 6], [false, 1, 3]]);
  assert.equal(p.total, 830);
});
test('plan: se bloquean inexistentes, cantidades inválidas, ambiguos y stock insuficiente', () => {
  const ctx = contexto(crearBase());
  const inv = { p6: { id: 'p6', nombre: 'P6', stock: 1, uds_sueltas: 0, uds_empaque: 6 }, p1: { id: 'p1', nombre: 'P1', stock: 9, uds_sueltas: 0, uds_empaque: 1 } };
  const casos = [
    [{ nombre: 'sin prod', cantidad: 1, precio_unitario: 1, precio_total: 1, tipo: 'und' }, /no está vinculado/],
    [{ prod_id: 'zz', nombre: 'x', cantidad: 1, precio_unitario: 1, precio_total: 1, tipo: 'und' }, /ya no existe/],
    [{ prod_id: 'p1', nombre: 'x', cantidad: 1.5, precio_unitario: 1, precio_total: 1.5, tipo: 'und' }, /cantidad no válida/],
    [{ prod_id: 'p1', nombre: 'x', cantidad: 0, precio_unitario: 1, precio_total: 0, tipo: 'und' }, /cantidad no válida/],
    [{ prod_id: 'p1', nombre: 'x', cantidad: 2, precio_unitario: 10, precio_total: 50, tipo: 'und' }, /inconsistente/],
    [{ prod_id: 'p6', nombre: 'x', cantidad: 1, precio_unitario: 1, precio_total: 1 }, /no indica si se cotizó por unidad o por empaque/],
    [{ prod_id: 'p1', nombre: 'x', cantidad: 1, precio_unitario: 1, precio_total: 1, tipo: 'emp' }, /hoy el producto no tiene empaque/],
    [{ prod_id: 'p1', nombre: 'x', cantidad: 1, precio_unitario: 1, precio_total: 1, tipo: 'caja' }, /tipo de venta desconocido/],
    [{ prod_id: 'p6', nombre: 'x', cantidad: 2, precio_unitario: 6, precio_total: 12, tipo: 'emp' }, /stock insuficiente/]
  ];
  for (const [it, re] of casos) {
    const p = ctx.construirPlanConversionCot([it], inv);
    assert.equal(p.ok, false, JSON.stringify(it)); assert.match(p.errores.join(' '), re);
    assert.equal(p.lineas.length, 0);
  }
});
test('conversión bloqueada por plan: la preparación no escribe nada', async () => {
  const s = semilla(); s.cotizaciones[0].items[0].cantidad = 100; s.cotizaciones[0].items[0].precio_total = 1000000;
  const base = crearBase(s); const ctx = contexto(base);
  const prep = await ctx.prepararConversionCot(COT);
  assert.equal(prep.plan.ok, false);
  assert.equal(base.log.filter(x => x.method !== 'GET').length, 0);
});

/* ============ 4. PAGO ============ */
test('validación del pago: efectivo, transferencia, crédito y contado por cobertura', () => {
  const ctx = contexto(crearBase()); const cli = { id: ANA };
  assert.ok(ctx.validarPagoConvCot({ tipo: 'efectivo' }, 1000, null).ok);
  assert.equal(ctx.validarPagoConvCot({ tipo: 'transferencia' }, 1000, null).ok, false);
  const t = ctx.validarPagoConvCot({ tipo: 'transferencia', origen: 'Nequi' }, 1000, null);
  assert.ok(t.ok); assert.equal(t.pago.origen, 'Nequi');
  assert.match(ctx.validarPagoConvCot({ tipo: 'credito', plazo: '30', abono: '' }, 1000, null).errores.join(), /cliente registrado/);
  assert.match(ctx.validarPagoConvCot({ tipo: 'credito', plazo: '0', abono: '' }, 1000, cli).errores.join(), /plazo/);
  assert.match(ctx.validarPagoConvCot({ tipo: 'credito', plazo: '30', abono: '-5' }, 1000, cli).errores.join(), /abono inicial no es válido/);
  assert.match(ctx.validarPagoConvCot({ tipo: 'credito', plazo: '30', abono: '2000', medioAbono: 'efectivo' }, 1000, cli).errores.join(), /supera el total/);
  assert.match(ctx.validarPagoConvCot({ tipo: 'credito', plazo: '30', abono: '200' }, 1000, cli).errores.join(), /medio del abono/);
  assert.match(ctx.validarPagoConvCot({ tipo: 'credito', plazo: '30', abono: '200', medioAbono: 'transferencia' }, 1000, cli).errores.join(), /origen de la transferencia del abono/);
  const c0 = ctx.validarPagoConvCot({ tipo: 'credito', plazo: '15', abono: '' }, 1000, cli);
  assert.ok(c0.ok); assert.equal(c0.pago.estado, 'credito'); assert.equal(c0.pago.abono, 0); assert.equal(c0.pago.saldo, 1000);
  const cub = ctx.validarPagoConvCot({ tipo: 'credito', plazo: '30', abono: '1000', medioAbono: 'efectivo' }, 1000, null);
  assert.ok(cub.ok, 'cubrir el total no exige cliente'); assert.equal(cub.pago.cubreTotal, true); assert.equal(cub.pago.estado, 'completada');
});
test('cancelar: abrir el resumen solo lee, no escribe', async () => {
  const base = crearBase(semilla()); const ctx = contexto(base);
  await ctx.prepararConversionCot(COT);
  assert.equal(base.log.filter(x => x.method !== 'GET').length, 0);
  assert.equal(base.T.cotizaciones[0].estado, 'aprobada');
});

/* ============ 5. CONCURRENCIA Y REINTENTOS ============ */
/* ============ LIBERACION Y PETICIONES TARDIAS ============ */
/* ============ PUNTOS ============ */
/* ============ VISIBILIDAD ============ */
/* ============ 6. Utilidades ============ */
