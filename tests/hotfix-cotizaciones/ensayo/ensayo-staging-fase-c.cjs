'use strict';
/* FASE C del ensayo en el staging ca10112ba2: la RPC de conversion por PostgREST REAL como usuario FICTICIO autenticado.
   Habla SOLO con el servidor local de ensayo (servidor-ensayo-staging.cjs), que inyecta la sesion: este guion no maneja
   credenciales. Todo lo que crea es identificable: productos ens-*, cliente y cotizaciones con "(ENSAYO)".
   - No sobrescribe: si un id previsto ya existe, solo lo reutiliza si es de ensayo; si no, se detiene.
   - No borra nada ni modifica datos anteriores. No hay apertura anonima: anon solo se usa para comprobar que NO puede.
   Resultado: tabla en pantalla, resultado-fase-c-<fecha>.json e inventario-registros-ensayo-fase-c-<fecha>.json (solo ids). */
const crypto = require('node:crypto'), fs = require('node:fs'), path = require('node:path');
const DECOY = '00000000-0000-4000-8000-000000000000';
const uuid = () => crypto.randomUUID();

async function ejecutar({ base, log, fetchFn }) {
  const f = fetchFn || fetch, out = log || (() => {});
  async function api(metodo, ruta, cuerpo, o) {
    o = o || {};
    const h = { 'content-type': 'application/json', Prefer: o.prefer || 'return=representation' };
    if (o.sinSesion) h['x-ensayo-sin-sesion'] = '1';
    const r = await f(base + '/rest/v1/' + ruta, { method: metodo, headers: h, body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo) });
    const txt = await r.text(); let json = null; try { json = txt ? JSON.parse(txt) : null; } catch (e) { /* no JSON */ }
    return { status: r.status, json, texto: txt };
  }
  const resultados = [], inv = { productos: [], clientes: [], cotizaciones: [], ventas: [], detalles: [], carteras: [], abonos: [], operaciones: [] };
  const marca = (nombre, ok, detalle, http) => { resultados.push({ nombre, ok: !!ok, detalle: detalle || '', http: http || null }); out((ok ? '  OK   ' : '  FALLA') + ' ' + nombre + (detalle ? ' — ' + detalle : '')); return !!ok; };
  const cod = r => r.json && r.json.code;
  const abortar = (m) => { throw new Error(m); };

  /* ---------- 0) destino y sesion ---------- */
  out('0) Destino, sesión y accesos que deben estar cerrados');
  const g = await (await f(base + '/__guarda')).json().catch(() => null);
  if (!g || g.proyecto !== 'ca10112ba2') abortar('El servidor de ensayo no confirma el staging ca10112ba2. Detenido.');
  const ses = await api('POST', 'rpc/lacava_mi_sesion', {});
  if (ses.status !== 200 || !ses.json || !ses.json.licencia) abortar('La sesión del usuario ficticio no es válida (HTTP ' + ses.status + '). Detenido.');
  const LIC = ses.json.licencia;
  marca('Sesión autenticada del usuario ficticio (H1): licencia y rol obtenidos', true, 'licencia "' + LIC + '", rol ' + ses.json.rol + ', ventas habilitadas: ' + ses.json.ventas_habilitadas);
  const aInfo = await api('POST', 'rpc/cotizacion_conversion_info', { p_id_licencia: LIC, p_cotizacion_id: DECOY }, { sinSesion: true });
  marca('anon (sin sesión) NO puede ejecutar cotizacion_conversion_info', [401, 403].includes(aInfo.status), 'HTTP ' + aInfo.status + ' ' + (cod(aInfo) || ''), aInfo.status);
  const aConv = await api('POST', 'rpc/convertir_cotizacion_atomica', { p_id_licencia: LIC, p_cotizacion_id: DECOY, p_op_clave: 'conv-' + uuid(), p_cotizacion_updated_at: new Date().toISOString(), p_pago: { tipo: 'efectivo' }, p_cliente_id: null, p_entrega: {} }, { sinSesion: true });
  marca('anon (sin sesión) NO puede ejecutar convertir_cotizacion_atomica (cotización señuelo; nada se escribe)', [401, 403].includes(aConv.status), 'HTTP ' + aConv.status + ' ' + (cod(aConv) || ''), aConv.status);
  const aReg = await api('GET', 'cotizacion_conversiones?select=*&limit=1', undefined, { sinSesion: true });
  marca('anon NO puede leer el registro (401/403)', [401, 403].includes(aReg.status), 'HTTP ' + aReg.status + ' ' + (cod(aReg) || ''), aReg.status);
  const uReg = await api('GET', 'cotizacion_conversiones?select=*&limit=1');
  marca('authenticated NO puede leer el registro (401/403)', [401, 403].includes(uReg.status), 'HTTP ' + uReg.status + ' ' + (cod(uReg) || ''), uReg.status);
  const regFalso = { op_clave: 'conv-' + uuid(), id_licencia: LIC, cotizacion_id: uuid(), venta_id: uuid(), huella: 'x', resultado: { ok: true } };
  for (const [quien, so] of [['anon', true], ['authenticated', false]]) {
    const w = await api('POST', 'cotizacion_conversiones', regFalso, { sinSesion: so });
    marca(quien + ' NO puede insertar una confirmación falsa en el registro (401/403)', [401, 403].includes(w.status), 'HTTP ' + w.status + ' ' + (cod(w) || ''), w.status);
    if (w.status < 300) abortar('El registro aceptó una inserción directa. Detenido: es un hallazgo grave.');
    for (const [m, ruta] of [['PATCH', 'cotizacion_conversiones?op_clave=neq.ensayo'], ['DELETE', 'cotizacion_conversiones?op_clave=neq.ensayo']]) {
      const x = await api(m, ruta, m === 'PATCH' ? { huella: 'y' } : undefined, { sinSesion: so });
      marca(quien + ' NO puede ' + (m === 'PATCH' ? 'modificar' : 'borrar') + ' el registro (401/403)', [401, 403].includes(x.status), 'HTTP ' + x.status, x.status);
      if (x.status < 300) abortar('El registro aceptó ' + m + ' directo. Detenido.');
    }
  }

  /* ---------- 1) datos ficticios (sin sobrescribir) ---------- */
  out('1) Datos ficticios identificables (no se sobrescribe nada existente)');
  const PID = { c6: 'ens-cerveza6', ron: 'ens-ron' }, CLI = '5e5e5e5e-0000-4000-8000-0000000000e1';
  const ex = await api('GET', 'inventario?id=in.(%22ens-cerveza6%22,%22ens-ron%22)&select=id,nombre,stock,uds_sueltas,uds_empaque');
  if (ex.status !== 200) abortar('No se pudo leer el inventario (HTTP ' + ex.status + ').');
  const hay = Object.fromEntries(ex.json.map(p => [p.id, p]));
  for (const p of ex.json) if (!/\(ENSAYO\)/.test(p.nombre || '')) abortar('El id ' + p.id + ' ya existe y NO es de ensayo. Detenido: no se sobrescribe.');
  const nuevos = [];
  if (!hay[PID.c6]) nuevos.push({ id: PID.c6, nombre: 'Cerveza x6 (ENSAYO)', categoria: 'Ensayo', precio_venta: 60000, precio_costo: 40000, stock: 100, uds_sueltas: 2, uds_empaque: 6 });
  if (!hay[PID.ron]) nuevos.push({ id: PID.ron, nombre: 'Ron 750 (ENSAYO)', categoria: 'Ensayo', precio_venta: 80000, precio_costo: 50000, stock: 100, uds_sueltas: 0, uds_empaque: 1 });
  if (nuevos.length) {
    const c = await api('POST', 'inventario', nuevos);
    marca('Productos ficticios creados (' + nuevos.map(p => p.id).join(', ') + ')', c.status === 201, 'HTTP ' + c.status + (c.status !== 201 ? ' ' + (c.json && c.json.message || '') : ''), c.status);
    if (c.status !== 201) abortar('No se pudieron crear los productos ficticios.');
  }
  inv.productos = [PID.c6, PID.ron].map(id => ({ id, creado_en_esta_ejecucion: !hay[id] }));
  const exC = await api('GET', 'clientes_frecuentes?id=eq.' + CLI + '&select=id,nombre');
  if (exC.json && exC.json.length) { if (!/\(ENSAYO\)/.test(exC.json[0].nombre || '')) abortar('El cliente previsto ya existe y no es de ensayo. Detenido.'); }
  else {
    const c = await api('POST', 'clientes_frecuentes', { id: CLI, nombre: 'Cliente Ficticio (ENSAYO)', whatsapp: '3000000001', direccion: 'Calle Ficticia 1', detalle: 'Apto 1' });
    marca('Cliente ficticio creado', c.status === 201, 'HTTP ' + c.status, c.status);
    if (c.status !== 201) abortar('No se pudo crear el cliente ficticio.');
  }
  inv.clientes = [{ id: CLI, creado_en_esta_ejecucion: !(exC.json && exC.json.length) }];

  const items = {
    c6und: { prod_id: PID.c6, nombre: 'Cerveza x6 (ENSAYO)', cantidad: 3, precio_unitario: 10000, precio_total: 30000, tipo: 'und', _precioBase: 10000, descItem: 0 },
    c6emp: { prod_id: PID.c6, nombre: 'Cerveza x6 (ENSAYO) (Sixpack)', cantidad: 1, precio_unitario: 60000, precio_total: 60000, tipo: 'emp', _precioBase: 60000, descItem: 0 },
    ron: { prod_id: PID.ron, nombre: 'Ron 750 (ENSAYO)', cantidad: 2, precio_unitario: 80000, precio_total: 160000, tipo: 'und', _precioBase: 80000, descItem: 0 }
  };
  let numero = Date.now();
  async function nuevaCot(lista) {
    const id = uuid(), total = lista.reduce((s, i) => s + i.precio_total, 0);
    const r = await api('POST', 'cotizaciones', { id, id_licencia: LIC, numero_local: ++numero, numero: 1, cliente_nombre: 'Cliente Ficticio (ENSAYO)', cliente_whatsapp: '3000000001', estado: 'aprobada', items: lista, total, fecha_creacion: new Date().toISOString() });
    if (r.status !== 201) abortar('No se pudo crear la cotización ficticia (HTTP ' + r.status + '): ' + (r.json && r.json.message || ''));
    inv.cotizaciones.push(id);
    return { id, updated_at: r.json[0].updated_at, total };
  }
  const clave = () => 'conv-' + uuid();
  const conv = (c, o) => { const k = o.clave || clave(); return api('POST', 'rpc/convertir_cotizacion_atomica', { p_id_licencia: LIC, p_cotizacion_id: c.id, p_op_clave: k, p_cotizacion_updated_at: o.ver || c.updated_at, p_pago: Object.assign({ total_esperado: c.total }, o.pago || { tipo: 'efectivo' }), p_cliente_id: o.cliente === null ? null : (o.cliente || CLI), p_entrega: o.entrega || { direccion: 'Calle Ficticia 1', detalle: 'Apto 1' } }).then(r => { r.clave = k; if (r.status === 200 && r.json && r.json.ok && !r.json.repetida) inv.operaciones.push({ clave: k, cotizacion_id: c.id, venta_id: r.json.venta_id }); return r; }); };
  const pool = async (pid) => { const r = await api('GET', 'inventario?id=eq.' + pid + '&select=stock,uds_sueltas,uds_empaque'); const p = r.json[0]; return p.stock * p.uds_empaque + p.uds_sueltas; };
  async function verificar(nombre, c, r, esperado) {
    /* venta, detalle, cartera, abono y vinculo reales, leidos como authenticated (RLS) */
    const j = r.json || {};
    if (r.status !== 200 || !j.ok) { marca(nombre + ': conversión', false, 'HTTP ' + r.status + ' ' + (cod(r) || '') + ' ' + (j.message || (r.json && r.json.message) || ''), r.status); return null; }
    const v = (await api('GET', 'ventas?id=eq.' + j.venta_id + '&select=*')).json;
    if (!v || !v.length) { marca(nombre + ': la venta es legible como authenticated', false, 'la venta existe (la RPC respondio) pero RLS no la muestra: el id_cliente del perfil no coincide con el de la venta'); return null; }
    const venta = v[0]; inv.ventas.push(venta.id);
    const det = (await api('GET', 'detalle_ventas?venta_id=eq.' + venta.id + '&select=*&order=cantidad')).json || []; det.forEach(d => inv.detalles.push(d.id));
    const cart = (await api('GET', 'cartera?venta_id=eq.' + venta.id + '&select=*')).json || []; cart.forEach(x => inv.carteras.push(x.id));
    const abs = cart.length ? ((await api('GET', 'cartera_abonos?cartera_id=eq.' + cart[0].id + '&select=*')).json || []) : []; abs.forEach(x => inv.abonos.push(x.id));
    const cot = (await api('GET', 'cotizaciones?id=eq.' + c.id + '&select=estado,venta_id')).json[0];
    const okV = venta.estado === esperado.estado && venta.metodo_pago === esperado.metodo && Math.round(venta.total) === Math.round(c.total) && cot.estado === 'convertida' && cot.venta_id === venta.id;
    marca(nombre + ': venta, estado y vínculo con la cotización', okV, 'venta #' + venta.numero_venta + ' ' + venta.estado + '/' + venta.metodo_pago + ' total ' + Math.round(venta.total) + ' vinculada: ' + (cot.venta_id === venta.id), r.status);
    marca(nombre + ': detalle (unidad/empaque aplicados y costos de v5)', det.length === esperado.lineas && det.every(d => d.costo_registrado === true || d.costo_ficha_venta != null), det.map(d => d.prod_id + ' x' + d.cantidad + (d.es_unidad ? ' und' : ' emp') + ' (x' + d.uds_empaque + ')').join('; '));
    marca(nombre + ': cartera y abono', cart.length === esperado.cartera && abs.length === esperado.abonos && (!esperado.cartera || Math.round(cart[0].saldo_pendiente) === Math.round(esperado.saldo)), cart.length ? 'cartera saldo ' + Math.round(cart[0].saldo_pendiente) + ' (' + cart[0].estado_cartera + '), abonos ' + abs.length + (abs[0] ? ' de ' + Math.round(abs[0].monto) + ' (' + abs[0].medio_pago + ')' : '') : 'sin cartera');
    return { venta, det, cart, abs };
  }

  /* ---------- 2) pagos ---------- */
  out('2) Contado, transferencia, crédito sin abono y con abono parcial');
  const unidades = (n6, ron) => ({ c6: n6, ron });
  const p0 = { c6: await pool(PID.c6), ron: await pool(PID.ron) };
  const A = await nuevaCot([items.c6und, items.c6emp, items.ron]), kA = clave();
  const rA = await conv(A, { clave: kA, pago: { tipo: 'efectivo' } });
  const vA = await verificar('Efectivo', A, rA, { estado: 'completada', metodo: 'efectivo', lineas: 3, cartera: 0, abonos: 0 });
  marca('Efectivo: inventario descontado una vez (cerveza −9 und, ron −2)', (p0.c6 - await pool(PID.c6)) === 9 && (p0.ron - await pool(PID.ron)) === 2);
  if (vA) marca('Efectivo: dirección y detalle confirmados guardados en la venta', vA.venta.direccion_entrega === 'Calle Ficticia 1' && vA.venta.detalle_entrega === 'Apto 1');
  const B = await nuevaCot([items.ron]), pB = await pool(PID.ron);
  const rB = await conv(B, { pago: { tipo: 'transferencia', origen: 'Nequi' } });
  const vB = await verificar('Transferencia', B, rB, { estado: 'completada', metodo: 'transferencia', lineas: 1, cartera: 0, abonos: 0 });
  if (vB) marca('Transferencia: origen guardado y descuento de 2 und de ron', vB.venta.notas === 'Origen: Nequi' && (pB - await pool(PID.ron)) === 2, 'notas "' + vB.venta.notas + '"');
  const C = await nuevaCot([items.ron]);
  const rC = await conv(C, { pago: { tipo: 'credito', plazo: 15, abono: 0 } });
  await verificar('Crédito sin abono', C, rC, { estado: 'credito', metodo: 'efectivo', lineas: 1, cartera: 1, abonos: 0, saldo: 160000 });
  const D = await nuevaCot([items.c6emp, items.ron]);
  const rD = await conv(D, { pago: { tipo: 'credito', plazo: 30, abono: 50000, medio_abono: 'transferencia', origen_abono: 'Llave Bancolombia' } });
  const vD = await verificar('Crédito con abono parcial', D, rD, { estado: 'credito', metodo: 'transferencia', lineas: 2, cartera: 1, abonos: 1, saldo: 170000 });
  if (vD && vD.abs[0]) marca('Crédito con abono parcial: abono inicial por 50 000, medio transferencia', Math.round(vD.abs[0].monto) === 50000 && vD.abs[0].medio_pago === 'transferencia', 'registrado_por "' + vD.abs[0].registrado_por + '" (lo fija H1 con el responsable del perfil)');
  const E = await nuevaCot([items.ron]);
  const rE = await conv(E, { pago: { tipo: 'credito', plazo: 30, abono: 160000, medio_abono: 'efectivo' } });
  await verificar('Abono que cubre el total (contado)', E, rE, { estado: 'completada', metodo: 'efectivo', lineas: 1, cartera: 0, abonos: 0 });

  /* ---------- 3) reintentos, conflicto y datos invalidos ---------- */
  out('3) Reintento con la misma clave, conflicto de clave y rechazos');
  const nV = async (c) => ((await api('GET', 'ventas?cotizacion_id=eq.' + c.id + '&select=id')).json || []).length;
  const antes = await pool(PID.c6);
  const rA2 = await conv(A, { clave: kA, pago: { tipo: 'efectivo' }, ver: A.updated_at });
  marca('Reintento con la misma clave: misma venta, repetida y verificada, sin escribir', rA2.status === 200 && rA2.json.repetida === true && rA2.json.verificada === true && rA2.json.venta_id === rA.json.venta_id && await nV(A) === 1 && await pool(PID.c6) === antes, 'HTTP ' + rA2.status, rA2.status);
  const rA3 = await conv(A, { clave: kA, pago: { tipo: 'transferencia', origen: 'Nequi' }, ver: A.updated_at });
  marca('Misma clave con otros datos: CV020 (HTTP 400)', cod(rA3) === 'CV020' && rA3.status === 400, 'HTTP ' + rA3.status + ' ' + (cod(rA3) || ''), rA3.status);
  const rA4 = await conv(A, { pago: { tipo: 'efectivo' }, ver: A.updated_at });
  marca('Cotización ya convertida con otra clave: CV011', cod(rA4) === 'CV011', 'HTTP ' + rA4.status + ' ' + (cod(rA4) || ''), rA4.status);
  const F = await nuevaCot([Object.assign({}, items.ron, { cantidad: 100000, precio_total: 8000000000 })]), pF = await pool(PID.ron);
  const rF = await conv(F, { pago: { tipo: 'efectivo' } });
  marca('Stock insuficiente: CV037, sin descontar ni crear venta', cod(rF) === 'CV037' && await pool(PID.ron) === pF && await nV(F) === 0, 'HTTP ' + rF.status + ' ' + (cod(rF) || ''), rF.status);
  const G = await nuevaCot([items.ron]);
  const rG = await conv(G, { pago: { tipo: 'efectivo' }, ver: '2001-01-01T00:00:00+00:00' });
  marca('Cotización cambiada después del resumen: CV012', cod(rG) === 'CV012' && await nV(G) === 0, 'HTTP ' + rG.status + ' ' + (cod(rG) || ''), rG.status);
  const Hh = await nuevaCot([items.ron]);
  const rH = await conv(Hh, { pago: { tipo: 'credito', plazo: 30, abono: 1000, medio_abono: 'efectivo' }, cliente: null });
  marca('Crédito sin cliente identificado: CV045', cod(rH) === 'CV045' && await nV(Hh) === 0, 'HTTP ' + rH.status + ' ' + (cod(rH) || ''), rH.status);

  /* ---------- 4) concurrencia ---------- */
  out('4) Dos dispositivos a la vez');
  const I = await nuevaCot([items.ron]), pI = await pool(PID.ron);
  const [h1, h2, h3] = await Promise.all([conv(I, { pago: { tipo: 'efectivo' } }), conv(I, { pago: { tipo: 'transferencia', origen: 'Nequi' } }), conv(I, { pago: { tipo: 'efectivo' } })]);
  const oks = [h1, h2, h3].filter(r => r.status === 200);
  marca('Tres claves distintas a la vez: una sola venta y un solo descuento', oks.length === 1 && [h1, h2, h3].filter(r => r.status !== 200).every(r => ['CV011', 'CV050'].includes(cod(r))) && await nV(I) === 1 && (pI - await pool(PID.ron)) === 2, [h1, h2, h3].map(r => r.status + ':' + (cod(r) || 'ok')).join(' '));
  const J = await nuevaCot([items.ron]), kJ = clave();
  const [j1, j2] = await Promise.all([conv(J, { clave: kJ }), conv(J, { clave: kJ })]);
  marca('Dos envíos con la MISMA clave a la vez: ambos reciben la misma venta', j1.status === 200 && j2.status === 200 && j1.json.venta_id === j2.json.venta_id && await nV(J) === 1, j1.status + '/' + j2.status);
  for (const c of [I, J]) { const v = (await api('GET', 'ventas?cotizacion_id=eq.' + c.id + '&select=id')).json || []; v.forEach(x => { if (!inv.ventas.includes(x.id)) inv.ventas.push(x.id); }); }

  /* ---------- 5) estado final ---------- */
  const info = [];
  for (const id of inv.cotizaciones) { const r = await api('POST', 'rpc/cotizacion_conversion_info', { p_id_licencia: LIC, p_cotizacion_id: id }); info.push(...((r.json && r.json.operaciones) || []).map(o => ({ cotizacion_id: id, venta_id: o.venta_id, venta_existe: o.venta_existe }))); }
  inv.registro_por_info_rpc = info;
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
    fs.writeFileSync(path.join(dir, 'resultado-fase-c-' + t + '.json'), JSON.stringify({ fecha: new Date().toISOString(), total: r.total, fallas: r.fallas, resultados: r.resultados }, null, 1));
    fs.writeFileSync(path.join(dir, 'inventario-registros-ensayo-fase-c-' + t + '.json'), JSON.stringify(r.inventario, null, 1));
    console.log('Evidencia guardada en ' + dir); process.exit(r.fallas ? 1 : 0);
  }).catch(e => { console.error('DETENIDO: ' + e.message); process.exit(3); });
}
module.exports = { ejecutar };
