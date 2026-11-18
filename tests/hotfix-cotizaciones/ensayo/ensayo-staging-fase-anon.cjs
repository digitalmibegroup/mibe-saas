'use strict';
/* FASE ANON del ensayo en el staging ca10112ba2 (acceso anonimo TEMPORAL, ya abierto por FASE-ANON-ENSAYO-STAGING.ps1):
   los tres flujos por PostgREST REAL como anon, sin JWT ni sesion. Habla SOLO con el servidor local en modo --solo-anon.
   Todo lo que crea es identificable ("(ENSAYO)"); reutiliza los productos ens-* de la fase C. No borra ni modifica datos anteriores.
   Resultado: tabla en pantalla, resultado-fase-anon-<fecha>.json e inventario-registros-ensayo-fase-anon-<fecha>.json (solo ids). */
const crypto = require('node:crypto'), fs = require('node:fs'), path = require('node:path');
const uuid = () => crypto.randomUUID();
const LIC = 'lacava';

async function ejecutar({ base, log, fetchFn }) {
  const f = fetchFn || fetch, out = log || (() => {});
  async function api(metodo, ruta, cuerpo, o) {
    o = o || {};
    const h = { 'content-type': 'application/json', Prefer: o.prefer || 'return=representation' };
    const r = await f(base + '/rest/v1/' + ruta, { method: metodo, headers: h, body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo) });
    const txt = await r.text(); let json = null; try { json = txt ? JSON.parse(txt) : null; } catch (e) { /* no JSON */ }
    return { status: r.status, json, texto: txt, rango: r.headers.get('content-range') };
  }
  const resultados = [], inv = { productos: [], clientes: [], cotizaciones: [], ventas: [], detalles: [], carteras: [], abonos: [], operaciones: [] };
  const marca = (nombre, ok, detalle, http) => { resultados.push({ nombre, ok: !!ok, detalle: detalle || '', http: http || null }); out((ok ? '  OK    ' : '  FALLA ') + nombre + (detalle ? ' — ' + detalle : '')); return !!ok; };
  const cod = r => r.json && r.json.code;
  const abortar = m => { throw new Error(m); };
  const total = async (tabla, filtro) => { const r = await api('GET', tabla + '?select=id&limit=1' + (filtro ? '&' + filtro : ''), undefined, { prefer: 'count=exact' }); return Number((r.rango || '').split('/')[1]); };

  out('0) Destino, modo anon y accesos');
  const g = await (await f(base + '/__guarda')).json().catch(() => null);
  if (!g || g.proyecto !== 'ca10112ba2') abortar('El servidor de ensayo no confirma el staging ca10112ba2. Detenido.');
  if (!g.sesion || g.sesion.modo !== 'solo anon (sin sesion)') abortar('El servidor no esta en modo SOLO ANON. Detenido: esta fase no debe usar el JWT.');
  marca('El servidor esta en modo SOLO ANON (sin sesion ni JWT)', true, 'proyecto ca10112ba2');
  const leer = await api('GET', 'cotizaciones?select=id&limit=1');
  if (leer.status !== 200) abortar('anon no puede leer cotizaciones (HTTP ' + leer.status + ' ' + (cod(leer) || '') + '): la apertura temporal no esta activa. Detenido.');
  marca('anon lee cotizaciones (apertura temporal activa)', true, 'HTTP 200', 200);
  const ses = await api('POST', 'rpc/lacava_mi_sesion', {});
  marca('anon NO tiene sesion de H1 (lacava_mi_sesion rechazada)', [401, 403].includes(ses.status), 'HTTP ' + ses.status + ' ' + (cod(ses) || ''), ses.status);
  const noAbiertas = [];
  for (const t of ['gastos', 'caja_sesiones', 'puntos_clientes', 'ventas_espera', 'compras', 'inventario_bodega']) { const r = await api('GET', t + '?select=*&limit=1'); if (![401, 403].includes(r.status)) noAbiertas.push(t + ':' + r.status); }
  marca('Tablas ajenas a los tres flujos siguen cerradas a anon (gastos, caja, puntos, espera, compras, bodegas)', noAbiertas.length === 0, noAbiertas.join(', ') || 'todas 401/403');
  async function registroCerrado(etiqueta) {
    const regFalso = { op_clave: 'conv-' + uuid(), id_licencia: LIC, cotizacion_id: uuid(), venta_id: uuid(), huella: 'x', resultado: { ok: true } };
    const intentos = [['GET', 'cotizacion_conversiones?select=*&limit=1'], ['POST', 'cotizacion_conversiones', regFalso], ['PATCH', 'cotizacion_conversiones?op_clave=neq.ensayo', { huella: 'y' }], ['DELETE', 'cotizacion_conversiones?op_clave=neq.ensayo']];
    const malos = [];
    for (const [m, ruta, b] of intentos) { const r = await api(m, ruta, b); if (![401, 403].includes(r.status)) malos.push(m + ':' + r.status); }
    marca('anon NO puede leer, insertar, modificar ni borrar el registro de idempotencia ' + etiqueta, malos.length === 0, malos.join(', ') || 'GET/POST/PATCH/DELETE: 401/403');
    if (malos.length) abortar('El registro de idempotencia aceptó un acceso directo de anon. Detenido: hallazgo grave.');
  }
  await registroCerrado('(al inicio)');
  const noEnsayo0 = await total('ventas', 'cliente_nombre=not.ilike.*ENSAYO*'), prodReal0 = await total('inventario', 'id=not.ilike.ens-*');

  out('1) Crear cliente con dirección');
  const ex = await api('GET', 'inventario?id=in.(%22ens-cerveza6%22,%22ens-ron%22)&select=id,nombre,stock,uds_sueltas,uds_empaque');
  if (ex.status !== 200 || ex.json.length !== 2 || ex.json.some(p => !/\(ENSAYO\)/.test(p.nombre))) abortar('Faltan los productos ens-* de la fase C (o no son de ensayo). Detenido.');
  const PID = { c6: 'ens-cerveza6', ron: 'ens-ron' };
  const CLI = uuid();
  const cc = await api('POST', 'clientes_frecuentes', { id: CLI, id_licencia: LIC, nombre: 'Cliente Anon (ENSAYO)', whatsapp: '3000000003', direccion: 'Carrera 7 # 8-9 (ENSAYO)', detalle: 'Torre 2 apto 301 (ENSAYO)' });
  marca('Cliente creado como anon', cc.status === 201, 'HTTP ' + cc.status + ' ' + (cc.status !== 201 ? (cc.json && cc.json.message || '') : ''), cc.status);
  if (cc.status !== 201) abortar('No se pudo crear el cliente como anon.');
  inv.clientes.push(CLI);
  const rc = await api('GET', 'clientes_frecuentes?id=eq.' + CLI + '&select=*');
  const cl = rc.json && rc.json[0];
  marca('Cliente releído con su dirección y detalle', cl && cl.direccion === 'Carrera 7 # 8-9 (ENSAYO)' && cl.detalle === 'Torre 2 apto 301 (ENSAYO)' && cl.nombre === 'Cliente Anon (ENSAYO)', cl ? 'dirección "' + cl.direccion + '"' : 'no se leyó');

  out('2) Guardar y reabrir una cotización');
  const items = {
    ron: { prod_id: PID.ron, nombre: 'Ron 750 (ENSAYO)', cantidad: 2, precio_unitario: 80000, precio_total: 160000, tipo: 'und', _precioBase: 80000, descItem: 0 },
    c6emp: { prod_id: PID.c6, nombre: 'Cerveza x6 (ENSAYO) (Sixpack)', cantidad: 1, precio_unitario: 60000, precio_total: 60000, tipo: 'emp', _precioBase: 60000, descItem: 0 }
  };
  let numero = Date.now();
  async function nuevaCot(lista, estado) {
    const id = uuid(), tot = lista.reduce((s, i) => s + i.precio_total, 0);
    const r = await api('POST', 'cotizaciones', { id, id_licencia: LIC, numero_local: ++numero, numero: 1, cliente_nombre: 'Cliente Anon (ENSAYO)', cliente_whatsapp: '3000000003', estado: estado || 'pendiente', items: lista, total: tot, fecha_creacion: new Date().toISOString() });
    if (r.status !== 201) abortar('No se pudo crear la cotización como anon (HTTP ' + r.status + '): ' + (r.json && r.json.message || ''));
    inv.cotizaciones.push(id);
    return { id, updated_at: r.json[0].updated_at, total: tot };
  }
  const A = await nuevaCot([items.ron], 'pendiente');
  const reabierta = (await api('GET', 'cotizaciones?id=eq.' + A.id + '&select=*')).json[0];
  marca('Cotización guardada y reabierta con sus productos y total', reabierta && reabierta.items.length === 1 && reabierta.items[0].prod_id === PID.ron && Math.round(reabierta.total) === 160000 && reabierta.estado === 'pendiente', 'estado ' + (reabierta && reabierta.estado));
  const pa = await api('PATCH', 'cotizaciones?id=eq.' + A.id, { estado: 'aprobada' });
  const A2 = (await api('GET', 'cotizaciones?id=eq.' + A.id + '&select=estado,updated_at')).json[0];
  marca('Cotización modificada (aprobada) y reabierta', pa.status < 300 && A2.estado === 'aprobada', 'HTTP ' + pa.status + ', estado ' + A2.estado, pa.status);
  A.updated_at = A2.updated_at;
  const B = await nuevaCot([items.c6emp, items.ron], 'aprobada');

  out('3) Conversión de contado y de crédito con abono');
  const clave = () => 'conv-' + uuid();
  const conv = (c, o) => { const k = o.clave || clave(); return api('POST', 'rpc/convertir_cotizacion_atomica', { p_id_licencia: LIC, p_cotizacion_id: c.id, p_op_clave: k, p_cotizacion_updated_at: o.ver || c.updated_at, p_pago: Object.assign({ total_esperado: c.total }, o.pago), p_cliente_id: o.cliente === null ? null : (o.cliente || CLI), p_entrega: o.entrega || { direccion: 'Carrera 7 # 8-9 (ENSAYO)', detalle: 'Torre 2 apto 301 (ENSAYO)' } }).then(r => { r.clave = k; if (r.status === 200 && r.json && r.json.ok && !r.json.repetida) inv.operaciones.push({ clave: k, cotizacion_id: c.id, venta_id: r.json.venta_id }); return r; }); };
  const pool = async pid => { const p = (await api('GET', 'inventario?id=eq.' + pid + '&select=stock,uds_sueltas,uds_empaque')).json[0]; return p.stock * p.uds_empaque + p.uds_sueltas; };
  async function verificar(nombre, c, r, esp) {
    const j = r.json || {};
    if (r.status !== 200 || !j.ok) { marca(nombre + ': conversión', false, 'HTTP ' + r.status + ' ' + (cod(r) || '') + ' ' + (j.message || ''), r.status); return null; }
    const v = (await api('GET', 'ventas?id=eq.' + j.venta_id + '&select=*')).json;
    if (!v || !v.length) { marca(nombre + ': la venta es legible como anon', false, 'la RPC respondió pero anon no ve la venta'); return null; }
    const venta = v[0]; inv.ventas.push(venta.id);
    const det = (await api('GET', 'detalle_ventas?venta_id=eq.' + venta.id + '&select=*')).json || []; det.forEach(d => inv.detalles.push(d.id));
    const cart = (await api('GET', 'cartera?venta_id=eq.' + venta.id + '&select=*')).json || []; cart.forEach(x => inv.carteras.push(x.id));
    const abs = cart.length ? ((await api('GET', 'cartera_abonos?cartera_id=eq.' + cart[0].id + '&select=*')).json || []) : []; abs.forEach(x => inv.abonos.push(x.id));
    const cot = (await api('GET', 'cotizaciones?id=eq.' + c.id + '&select=estado,venta_id')).json[0];
    marca(nombre + ': venta, estado y vínculo con la cotización', venta.estado === esp.estado && venta.metodo_pago === esp.metodo && Math.round(venta.total) === Math.round(c.total) && cot.estado === 'convertida' && cot.venta_id === venta.id, 'venta #' + venta.numero_venta + ' ' + venta.estado + '/' + venta.metodo_pago + ' total ' + Math.round(venta.total) + ' vinculada: ' + (cot.venta_id === venta.id), r.status);
    marca(nombre + ': detalle con costos (v5)', det.length === esp.lineas && det.every(d => d.costo_registrado === true || d.costo_ficha_venta != null), det.map(d => d.prod_id + ' x' + d.cantidad + (d.es_unidad ? ' und' : ' emp')).join('; '));
    marca(nombre + ': cartera y abono', cart.length === esp.cartera && abs.length === esp.abonos && (!esp.cartera || Math.round(cart[0].saldo_pendiente) === Math.round(esp.saldo)), cart.length ? 'cartera saldo ' + Math.round(cart[0].saldo_pendiente) + ' (' + cart[0].estado_cartera + '), abonos ' + abs.length + (abs[0] ? ' de ' + Math.round(abs[0].monto) + ' (' + abs[0].medio_pago + ', registrado_por "' + abs[0].registrado_por + '")' : '') : 'sin cartera');
    marca(nombre + ': dirección y detalle guardados en la venta', venta.direccion_entrega === 'Carrera 7 # 8-9 (ENSAYO)' && venta.detalle_entrega === 'Torre 2 apto 301 (ENSAYO)');
    return { venta, det, cart, abs };
  }
  const p0 = { c6: await pool(PID.c6), ron: await pool(PID.ron) }, kA = clave();
  const rA = await conv(A, { clave: kA, pago: { tipo: 'efectivo' } });
  await verificar('Contado (efectivo)', A, rA, { estado: 'completada', metodo: 'efectivo', lineas: 1, cartera: 0, abonos: 0 });
  marca('Contado: inventario descontado una vez (ron −2 und)', (p0.ron - await pool(PID.ron)) === 2);
  const kB = clave(), p1 = { c6: await pool(PID.c6), ron: await pool(PID.ron) };
  const rB = await conv(B, { clave: kB, pago: { tipo: 'credito', plazo: 30, abono: 50000, medio_abono: 'transferencia', origen_abono: 'Nequi' } });
  const vB = await verificar('Crédito con abono', B, rB, { estado: 'credito', metodo: 'transferencia', lineas: 2, cartera: 1, abonos: 1, saldo: 170000 });
  marca('Crédito con abono: inventario descontado una vez (cerveza −6 und, ron −2 und)', (p1.c6 - await pool(PID.c6)) === 6 && (p1.ron - await pool(PID.ron)) === 2);
  if (vB && vB.abs[0]) marca('Crédito con abono: abono inicial 50 000 por transferencia', Math.round(vB.abs[0].monto) === 50000 && vB.abs[0].medio_pago === 'transferencia', 'registrado_por "' + vB.abs[0].registrado_por + '"');

  out('4) Reintento sin duplicar y conflictos');
  const nV = async c => ((await api('GET', 'ventas?cotizacion_id=eq.' + c.id + '&select=id')).json || []).length;
  const antes = { c6: await pool(PID.c6), ron: await pool(PID.ron) };
  const rA2 = await conv(A, { clave: kA, pago: { tipo: 'efectivo' }, ver: A.updated_at });
  marca('Reintento contado con la misma clave: misma venta, repetida y verificada', rA2.status === 200 && rA2.json.repetida === true && rA2.json.verificada === true && rA2.json.venta_id === rA.json.venta_id && await nV(A) === 1, 'HTTP ' + rA2.status, rA2.status);
  const rB2 = await conv(B, { clave: kB, pago: { tipo: 'credito', plazo: 30, abono: 50000, medio_abono: 'transferencia', origen_abono: 'Nequi' }, ver: B.updated_at });
  marca('Reintento crédito con la misma clave: misma venta, sin segunda cartera ni segundo abono', rB2.status === 200 && rB2.json.repetida === true && rB2.json.venta_id === rB.json.venta_id && await nV(B) === 1 && (await api('GET', 'cartera?venta_id=eq.' + rB.json.venta_id + '&select=id')).json.length === 1 && (vB ? (await api('GET', 'cartera_abonos?cartera_id=eq.' + vB.cart[0].id + '&select=id')).json.length === 1 : false), 'HTTP ' + rB2.status, rB2.status);
  marca('Los reintentos no tocaron el inventario', (await pool(PID.c6)) === antes.c6 && (await pool(PID.ron)) === antes.ron);
  const rA3 = await conv(A, { clave: kA, pago: { tipo: 'transferencia', origen: 'Nequi' }, ver: A.updated_at });
  marca('Misma clave con otros datos: CV020', cod(rA3) === 'CV020' && rA3.status === 400, 'HTTP ' + rA3.status + ' ' + (cod(rA3) || ''), rA3.status);
  const rA4 = await conv(A, { pago: { tipo: 'efectivo' }, ver: A.updated_at });
  marca('Cotización ya convertida con otra clave: CV011', cod(rA4) === 'CV011', 'HTTP ' + rA4.status + ' ' + (cod(rA4) || ''), rA4.status);
  const C = await nuevaCot([items.ron], 'aprobada'), kC = clave();
  const [j1, j2] = await Promise.all([conv(C, { clave: kC, pago: { tipo: 'efectivo' } }), conv(C, { clave: kC, pago: { tipo: 'efectivo' } })]);
  marca('Dos envíos con la MISMA clave a la vez: la misma venta y una sola', j1.status === 200 && j2.status === 200 && j1.json.venta_id === j2.json.venta_id && await nV(C) === 1, j1.status + '/' + j2.status);
  (await api('GET', 'ventas?cotizacion_id=eq.' + C.id + '&select=id')).json.forEach(x => { if (!inv.ventas.includes(x.id)) inv.ventas.push(x.id); });

  out('5) Registro de idempotencia y datos finales');
  await registroCerrado('(al final)');
  const info = [];
  for (const id of inv.cotizaciones) { const r = await api('POST', 'rpc/cotizacion_conversion_info', { p_id_licencia: LIC, p_cotizacion_id: id }); info.push(...((r.json && r.json.operaciones) || []).map(o => ({ cotizacion_id: id, venta_id: o.venta_id, venta_existe: o.venta_existe }))); }
  inv.registro_por_info_rpc = info;
  marca('Registro: una operación por cada conversión confirmada, todas con su venta', info.length === 3 && info.every(o => o.venta_existe === true), info.length + ' operaciones');
  marca('Ventas y productos reales intactos', (await total('ventas', 'cliente_nombre=not.ilike.*ENSAYO*')) === noEnsayo0 && (await total('inventario', 'id=not.ilike.ens-*')) === prodReal0, 'ventas no-ensayo: ' + noEnsayo0 + ', productos no-ensayo: ' + prodReal0);
  inv.licencia = LIC;
  const fin = resultados.filter(r => !r.ok).length;
  out('\nResumen: ' + (resultados.length - fin) + ' de ' + resultados.length + ' comprobaciones correctas' + (fin ? ', ' + fin + ' FALLARON.' : '.'));
  return { total: resultados.length, fallas: fin, resultados, inventario: inv };
}

if (require.main === module) {
  const base = process.argv[2] || 'http://127.0.0.1:5190';
  if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(base)) { console.error('La base debe ser el servidor local (http://127.0.0.1:<puerto>).'); process.exit(2); }
  ejecutar({ base, log: console.log }).then(r => {
    const dir = path.join(process.env.USERPROFILE || '.', 'LaCava-evidencia-local', 'hotfix-staging-ca10112ba2'); fs.mkdirSync(dir, { recursive: true });
    const t = new Date().toISOString().replace(/[:.]/g, '-');
    fs.writeFileSync(path.join(dir, 'resultado-fase-anon-' + t + '.json'), JSON.stringify({ fecha: new Date().toISOString(), total: r.total, fallas: r.fallas, resultados: r.resultados }, null, 1));
    fs.writeFileSync(path.join(dir, 'inventario-registros-ensayo-fase-anon-' + t + '.json'), JSON.stringify(r.inventario, null, 1));
    console.log('Evidencia guardada en ' + dir); process.exit(r.fallas ? 1 : 0);
  }).catch(e => { console.error('DETENIDO: ' + e.message); process.exit(3); });
}
module.exports = { ejecutar };
