'use strict';
/* ENSAYO de la conversion atomica mediante PostgREST REAL, en un proyecto Supabase SEPARADO.
   NO se ejecuta contra produccion: rechaza su huella. Escribe SOLO datos ficticios (ids propios,
   nombres con "(ENSAYO)"). Antes de usarlo hay que aplicar HOTFIX_COT_CONVERSION_ATOMICA.sql en
   ese proyecto de ensayo (con autorizacion expresa de Michel).
   Uso interactivo:   node ensayo-postgrest.cjs
   Pide la URL del proyecto y la clave anon (no se muestran ni se guardan) y una frase de confirmacion.
   Resultado: tabla en pantalla y un JSON en ./resultados/ (solo ficticios; sin la clave). */
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const HUELLA_PRODUCCION = 'cea2aa59bdf95443fef9d9a4b42bab3fd5a77bbb1131ac24b7ddc790eface400'; /* SHA-256 del ref de produccion */
const LIC = 'lacava';
const sha = t => crypto.createHash('sha256').update(t).digest('hex');
const uuid = () => crypto.randomUUID();
const esperar = ms => new Promise(r => setTimeout(r, ms));

function cliente(base, key, fetchFn) {
  const f = fetchFn || fetch;
  const H = { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json', Prefer: 'return=representation' };
  async function pedir(metodo, ruta, cuerpo, extra) {
    const r = await f(base + '/rest/v1/' + ruta, { method: metodo, headers: Object.assign({}, H, extra || {}), body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo) });
    const txt = await r.text(); let json = null; try { json = txt ? JSON.parse(txt) : null; } catch (e) { /* no JSON */ }
    return { status: r.status, json, texto: txt };
  }
  return {
    get: (ruta) => pedir('GET', ruta), post: (ruta, c, extra) => pedir('POST', ruta, c, extra),
    patch: (ruta, c) => pedir('PATCH', ruta, c), del: (ruta) => pedir('DELETE', ruta),
    rpc: (fn, args) => pedir('POST', 'rpc/' + fn, args)
  };
}

async function ejecutar({ url, key, fetchFn, log }) {
  const out = log || (() => {});
  const db = cliente(url.replace(/\/+$/, ''), key, fetchFn);
  const resultados = [];
  const marca = (nombre, ok, detalle, http) => { resultados.push({ nombre, ok: !!ok, detalle: detalle || '', http: http || null }); out((ok ? '  OK   ' : '  FALLA') + ' ' + nombre + (detalle ? ' — ' + detalle : '')); };
  const esperaVerdad = (nombre, cond, detalle, http) => marca(nombre, cond, cond ? (detalle || '') : 'no se cumplió: ' + (detalle || ''), http);

  /* ---------- datos ficticios ---------- */
  const PID = { c6: 'ens-cerveza6', ron: 'ens-ron' }, CLI = '5e5e5e5e-0000-4000-8000-0000000000e1';
  async function sembrar() {
    const a = await db.post('inventario?on_conflict=id', [
      { id: PID.c6, nombre: 'Cerveza x6 (ENSAYO)', categoria: 'Ensayo', precio_venta: 60000, precio_costo: 40000, stock: 100, uds_sueltas: 2, uds_empaque: 6, id_licencia: LIC },
      { id: PID.ron, nombre: 'Ron 750 (ENSAYO)', categoria: 'Ensayo', precio_venta: 80000, precio_costo: 50000, stock: 100, uds_sueltas: 0, uds_empaque: 1, id_licencia: LIC }
    ], { Prefer: 'return=representation,resolution=merge-duplicates' });
    const b = await db.post('clientes_frecuentes?on_conflict=id', [{ id: CLI, nombre: 'Cliente Ficticio (ENSAYO)', whatsapp: '3000000001', direccion: 'Calle Ficticia 1', detalle: 'Apto 1', id_licencia: LIC }], { Prefer: 'return=representation,resolution=merge-duplicates' });
    return a.status < 300 && b.status < 300;
  }
  const items = (sel) => ({
    c6und: { prod_id: PID.c6, nombre: 'Cerveza x6 (ENSAYO)', cantidad: 3, precio_unitario: 10000, precio_total: 30000, tipo: 'und', _precioBase: 10000, descItem: 0 },
    c6emp: { prod_id: PID.c6, nombre: 'Cerveza x6 (ENSAYO) (Sixpack)', cantidad: 1, precio_unitario: 60000, precio_total: 60000, tipo: 'emp', _precioBase: 60000, descItem: 0 },
    ron: { prod_id: PID.ron, nombre: 'Ron 750 (ENSAYO)', cantidad: 2, precio_unitario: 80000, precio_total: 160000, tipo: 'und', _precioBase: 80000, descItem: 0 }
  }[sel]);
  let numero = Math.floor(Date.now() / 1000) * 1000;
  async function nuevaCot(listaItems, extra) {
    const id = uuid(), total = listaItems.reduce((s, i) => s + i.precio_total, 0);
    const r = await db.post('cotizaciones', Object.assign({ id, id_licencia: LIC, numero_local: ++numero, numero: 1, cliente_nombre: 'Cliente Ficticio (ENSAYO)', cliente_whatsapp: '3000000001', estado: 'aprobada', items: listaItems, total, fecha_creacion: new Date().toISOString() }, extra || {}));
    if (r.status >= 300) throw new Error('No se pudo crear la cotización ficticia (' + r.status + '): ' + r.texto.slice(0, 200));
    return { id, updated_at: r.json[0].updated_at, total };
  }
  const clave = () => 'conv-' + uuid();
  const conv = (c, o) => db.rpc('convertir_cotizacion_atomica', {
    p_id_licencia: LIC, p_cotizacion_id: c.id, p_op_clave: o.clave || clave(), p_cotizacion_updated_at: o.ver || c.updated_at,
    p_pago: Object.assign({ total_esperado: c.total }, o.pago || { tipo: 'efectivo' }), p_cliente_id: o.cliente === null ? null : (o.cliente || CLI),
    p_entrega: o.entrega || { direccion: 'Calle Ficticia 1', detalle: 'Apto 1' }
  });
  const pool = async (pid) => { const r = await db.get('inventario?id=eq.' + pid + '&select=stock,uds_sueltas,uds_empaque'); const p = r.json[0]; return p.stock * p.uds_empaque + p.uds_sueltas; };
  const unaVenta = async (id) => (await db.get('ventas?id=eq.' + id + '&select=*')).json[0];
  const codigo = r => r.json && r.json.code;

  /* ---------- 0) preparacion ---------- */
  out('0) Preparación: función instalada, registro cerrado y datos ficticios');
  const pre = await db.rpc('convertir_cotizacion_atomica', { p_id_licencia: LIC, p_cotizacion_id: uuid(), p_op_clave: 'clave-no-valida', p_cotizacion_updated_at: new Date().toISOString(), p_pago: {}, p_cliente_id: null, p_entrega: {} });
  esperaVerdad('La función está instalada y responde por PostgREST (clave inválida → CV002)', codigo(pre) === 'CV002', 'HTTP ' + pre.status + ' código ' + codigo(pre), pre.status);
  if (codigo(pre) !== 'CV002') throw new Error('La función no está instalada en este proyecto (o PostgREST no recargó el esquema). Detén el ensayo.');
  esperaVerdad('Datos ficticios sembrados', await sembrar());
  const lecReg = await db.get('cotizacion_conversiones?select=*&limit=1');
  esperaVerdad('anon NO puede leer el registro (HTTP 401/403, código 42501)', [401, 403].includes(lecReg.status), 'HTTP ' + lecReg.status + ' ' + (codigo(lecReg) || ''), lecReg.status);
  const falso = await db.post('cotizacion_conversiones', { op_clave: clave(), id_licencia: LIC, cotizacion_id: uuid(), venta_id: uuid(), huella: 'x', resultado: { ok: true } });
  esperaVerdad('anon NO puede insertar una confirmación falsa en el registro (HTTP 401/403)', [401, 403].includes(falso.status), 'HTTP ' + falso.status + ' ' + (codigo(falso) || ''), falso.status);
  for (const [m, f] of [['UPDATE', () => db.patch('cotizacion_conversiones?op_clave=neq.ensayo', { huella: 'y' })], ['DELETE', () => db.del('cotizacion_conversiones?op_clave=neq.ensayo')]]) {
    const r = await f(); esperaVerdad('anon NO puede ' + m + ' el registro (HTTP 401/403)', [401, 403].includes(r.status), 'HTTP ' + r.status, r.status);
  }

  /* ---------- 1) pagos ---------- */
  out('1) Contado, transferencia, crédito sin y con abono; empaques y unidades');
  const p0 = { c6: await pool(PID.c6), ron: await pool(PID.ron) };
  const A = await nuevaCot([items('c6und'), items('c6emp'), items('ron')]);
  const kA = clave();
  const rA = await conv(A, { clave: kA, pago: { tipo: 'efectivo' } });
  esperaVerdad('Contado en efectivo: HTTP 200 y venta registrada', rA.status === 200 && rA.json && rA.json.ok === true && rA.json.estado === 'completada', 'HTTP ' + rA.status + (rA.json && rA.json.message ? ' ' + rA.json.message : ''), rA.status);
  if (rA.status === 200) {
    const vA = await unaVenta(rA.json.venta_id);
    const dA = (await db.get('ventas?id=eq.' + rA.json.venta_id + '&select=id')).json && (await db.get('detalle_ventas?venta_id=eq.' + rA.json.venta_id + '&select=prod_id,cantidad,es_unidad,uds_empaque&order=cantidad')).json;
    esperaVerdad('Detalle con unidad/empaque aplicados (3 und, 1 empaque x6, 2 und de ron)', dA.length === 3 && dA.some(d => d.prod_id === PID.c6 && d.es_unidad === true && d.cantidad === 3 && d.uds_empaque === 6) && dA.some(d => d.prod_id === PID.c6 && d.es_unidad === false && d.uds_empaque === 6), JSON.stringify(dA));
    esperaVerdad('Inventario descontado una vez (cerveza −9 und, ron −2)', (p0.c6 - await pool(PID.c6)) === 9 && (p0.ron - await pool(PID.ron)) === 2);
    esperaVerdad('Cotización convertida y vinculada', (await db.get('cotizaciones?id=eq.' + A.id + '&select=estado,venta_id')).json[0].venta_id === rA.json.venta_id);
    esperaVerdad('La venta guarda dirección y detalle confirmados', vA.direccion_entrega === 'Calle Ficticia 1' && vA.detalle_entrega === 'Apto 1');
  }
  const B = await nuevaCot([items('ron')]);
  const rB = await conv(B, { pago: { tipo: 'transferencia', origen: 'Nequi' } });
  esperaVerdad('Transferencia con origen', rB.status === 200 && (await unaVenta(rB.json.venta_id)).notas === 'Origen: Nequi', 'HTTP ' + rB.status, rB.status);
  const C = await nuevaCot([items('ron')]);
  const rC = await conv(C, { pago: { tipo: 'credito', plazo: 15, abono: 0 } });
  const cartC = rC.status === 200 ? (await db.get('cartera?venta_id=eq.' + rC.json.venta_id + '&select=total,saldo_pendiente')).json : [];
  esperaVerdad('Crédito sin abono: cartera por el total, sin abonos', rC.status === 200 && cartC.length === 1 && Number(cartC[0].saldo_pendiente) === 160000, 'HTTP ' + rC.status, rC.status);
  const D = await nuevaCot([items('c6emp'), items('ron')]);
  const rD = await conv(D, { pago: { tipo: 'credito', plazo: 30, abono: 50000, medio_abono: 'transferencia', origen_abono: 'Llave Bancolombia' } });
  esperaVerdad('Crédito con abono: venta a crédito', rD.status === 200 && rD.json.estado === 'credito' && Number(rD.json.saldo_pendiente) === 170000, 'HTTP ' + rD.status, rD.status);
  if (rD.status === 200) {
    const ab = await db.rpc('registrar_abono_cartera_atomico', { p_cartera_id: rD.json.cartera_id, p_id_licencia: LIC, p_monto: 20000, p_fecha: new Date().toISOString(), p_medio_pago: 'efectivo' });
    esperaVerdad('Un abono posterior con la RPC de producción se acepta (la cartera creada es compatible)', ab.status === 200 && ab.json && ab.json.ok === true, 'HTTP ' + ab.status + ' ' + (ab.json && ab.json.message || ''), ab.status);
  }
  const E = await nuevaCot([items('ron')]);
  const rE = await conv(E, { pago: { tipo: 'credito', plazo: 30, abono: 160000, medio_abono: 'efectivo' } });
  esperaVerdad('El abono que cubre el total se registra como contado, sin cartera', rE.status === 200 && rE.json.estado === 'completada' && (await db.get('cartera?venta_id=eq.' + rE.json.venta_id + '&select=id')).json.length === 0, 'HTTP ' + rE.status, rE.status);

  /* ---------- 2) reintentos y conflicto ---------- */
  out('2) Reintento, conflicto de operación y datos inválidos');
  const nVentas = async () => (await db.get('ventas?cotizacion_id=eq.' + A.id + '&select=id')).json.length;
  const antesP = await pool(PID.c6);
  const rA2 = await conv(A, { clave: kA, pago: { tipo: 'efectivo' }, ver: A.updated_at });
  esperaVerdad('Reintento con la misma clave: misma venta, repetida y verificada, sin escribir', rA2.status === 200 && rA2.json.repetida === true && rA2.json.verificada === true && rA2.json.venta_id === rA.json.venta_id && await nVentas() === 1 && await pool(PID.c6) === antesP, 'HTTP ' + rA2.status, rA2.status);
  const rA3 = await conv(A, { clave: kA, pago: { tipo: 'transferencia', origen: 'Nequi' }, ver: A.updated_at });
  esperaVerdad('Misma clave con otros datos: se rechaza (CV020, HTTP 400)', codigo(rA3) === 'CV020' && rA3.status === 400, 'HTTP ' + rA3.status + ' ' + codigo(rA3), rA3.status);
  const rA4 = await conv(A, { pago: { tipo: 'efectivo' }, ver: A.updated_at });
  esperaVerdad('Cotización ya convertida con otra clave: CV011', codigo(rA4) === 'CV011', 'HTTP ' + rA4.status + ' ' + codigo(rA4), rA4.status);
  const F = await nuevaCot([Object.assign(items('ron'), { cantidad: 1000, precio_unitario: 80000, precio_total: 80000000 })]);
  const antesF = await pool(PID.ron);
  const rF = await conv(F, { pago: { tipo: 'efectivo' } });
  esperaVerdad('Stock insuficiente: CV037, sin descontar ni crear venta', codigo(rF) === 'CV037' && await pool(PID.ron) === antesF && (await db.get('ventas?cotizacion_id=eq.' + F.id + '&select=id')).json.length === 0, 'HTTP ' + rF.status + ' ' + codigo(rF) + ' ' + (rF.json && rF.json.message || ''), rF.status);
  const G = await nuevaCot([items('ron')]);
  const rG = await conv(G, { pago: { tipo: 'efectivo' }, ver: '2001-01-01T00:00:00+00:00' });
  esperaVerdad('Cotización cambiada después del resumen: CV012', codigo(rG) === 'CV012', 'HTTP ' + rG.status + ' ' + codigo(rG), rG.status);

  /* ---------- 3) concurrencia ---------- */
  out('3) Dos dispositivos a la vez');
  const H = await nuevaCot([items('ron')]), p0H = await pool(PID.ron);
  const [h1, h2, h3] = await Promise.all([conv(H, { pago: { tipo: 'efectivo' } }), conv(H, { pago: { tipo: 'transferencia', origen: 'Nequi' } }), conv(H, { pago: { tipo: 'efectivo' }, cliente: null })]);
  const oks = [h1, h2, h3].filter(r => r.status === 200);
  esperaVerdad('Tres claves distintas a la vez: una sola venta y un solo descuento', oks.length === 1 && [h1, h2, h3].filter(r => r.status !== 200).every(r => ['CV011', 'CV050'].includes(codigo(r))) && (await db.get('ventas?cotizacion_id=eq.' + H.id + '&select=id')).json.length === 1 && (p0H - await pool(PID.ron)) === 2, [h1, h2, h3].map(r => r.status + ':' + (codigo(r) || 'ok')).join(' '));
  const I = await nuevaCot([items('ron')]), kI = clave();
  const [i1, i2] = await Promise.all([conv(I, { clave: kI }), conv(I, { clave: kI })]);
  esperaVerdad('Dos envíos con la MISMA clave a la vez: ambos reciben la misma venta', i1.status === 200 && i2.status === 200 && i1.json.venta_id === i2.json.venta_id, i1.status + '/' + i2.status);

  /* ---------- 4) venta eliminada por el flujo normal ---------- */
  out('4) Eliminar una venta convertida y reintentar');
  const J = await nuevaCot([items('c6und'), items('ron')]), kJ = clave();
  const pJ = { c6: await pool(PID.c6), ron: await pool(PID.ron) };
  const rJ = await conv(J, { clave: kJ });
  esperaVerdad('Conversión previa a la eliminación', rJ.status === 200, 'HTTP ' + rJ.status, rJ.status);
  if (rJ.status === 200) {
    /* pasos de eliminarVenta() del dashboard */
    await db.patch('cotizaciones?id=eq.' + J.id + '&venta_id=eq.' + rJ.json.venta_id, { venta_id: null, estado: 'convertida', updated_at: new Date().toISOString() });
    await db.del('detalle_ventas?venta_id=eq.' + rJ.json.venta_id);
    const dv = await db.del('ventas?id=eq.' + rJ.json.venta_id);
    esperaVerdad('La venta se elimina por el flujo normal (anon)', dv.status === 200 && dv.json.length === 1, 'HTTP ' + dv.status, dv.status);
    await db.patch('inventario?id=eq.' + PID.c6, { stock: Math.floor(pJ.c6 / 6), uds_sueltas: pJ.c6 % 6 });
    await db.patch('inventario?id=eq.' + PID.ron, { stock: pJ.ron, uds_sueltas: 0 });
    const antes = { c6: await pool(PID.c6), ron: await pool(PID.ron) };
    const rJ2 = await conv(J, { clave: kJ, ver: J.updated_at });
    esperaVerdad('Reintento tras eliminar la venta: CV022, no recrea la venta', codigo(rJ2) === 'CV022' && (await db.get('ventas?cotizacion_id=eq.' + J.id + '&select=id')).json.length === 0, 'HTTP ' + rJ2.status + ' ' + codigo(rJ2) + ' ' + (rJ2.json && rJ2.json.message || ''), rJ2.status);
    esperaVerdad('Y no vuelve a descontar inventario', await pool(PID.c6) === antes.c6 && await pool(PID.ron) === antes.ron);
    const info = await db.rpc('cotizacion_conversion_info', { p_id_licencia: LIC, p_cotizacion_id: J.id });
    esperaVerdad('La evidencia sigue ahí: cotizacion_conversion_info lista la operación con la venta eliminada', info.status === 200 && info.json.operaciones.length === 1 && info.json.operaciones[0].venta_existe === false, 'HTTP ' + info.status, info.status);
  }
  const fin = resultados.filter(r => !r.ok).length;
  out('\nResumen: ' + (resultados.length - fin) + ' de ' + resultados.length + ' comprobaciones correctas' + (fin ? ', ' + fin + ' FALLARON' : '.'));
  return { total: resultados.length, fallas: fin, resultados };
}

/* ---------- uso interactivo ---------- */
const { pedir } = require('./entrada-oculta.cjs');
async function main() {
  console.log('Ensayo de la conversión atómica por PostgREST REAL — proyecto SEPARADO, solo datos ficticios.');
  console.log('NO uses el proyecto de producción. Antes: aplicar HOTFIX_COT_CONVERSION_ATOMICA.sql en el proyecto de ensayo (con autorización).');
  const url = (await pedir('URL del proyecto de ENSAYO (https://xxxx.supabase.co): ')).replace(/\/+$/, '');
  const m = url.match(/^https:\/\/([a-z0-9]{20})\.supabase\.co$/);
  if (!m) { console.error('La URL debe ser https://<ref de 20 caracteres>.supabase.co. No se conectó.'); process.exit(2); }
  if (sha(m[1]) === HUELLA_PRODUCCION) { console.error('Ese es el proyecto de PRODUCCION. No se conectó ni se escribió nada.'); process.exit(4); }
  const key = await pedir('Clave anon del proyecto de ensayo (no se muestra): ', true, true);
  if (key.length < 20) { console.error('Clave no válida. No se conectó.'); process.exit(2); }
  const frase = await pedir('Para continuar escribe exactamente  ENSAYAR EN PROYECTO SEPARADO : ');
  if (frase !== 'ENSAYAR EN PROYECTO SEPARADO') { console.error('Confirmación distinta. No se conectó.'); process.exit(4); }
  const r = await ejecutar({ url, key, log: console.log });
  const dir = path.join(__dirname, 'resultados'); fs.mkdirSync(dir, { recursive: true });
  const ruta = path.join(dir, 'resultado-ensayo-' + new Date().toISOString().replace(/[:.]/g, '-') + '.json');
  fs.writeFileSync(ruta, JSON.stringify({ proyecto: m[1].slice(0, 4) + '…', fecha: new Date().toISOString(), total: r.total, fallas: r.fallas, resultados: r.resultados }, null, 2));
  console.log('Resultado guardado en ' + ruta + ' (sin la clave).');
  process.exit(r.fallas ? 1 : 0);
}
if (require.main === module) main().catch(e => { console.error('Error:', e.message); process.exit(3); });
module.exports = { ejecutar, HUELLA_PRODUCCION, sha };
