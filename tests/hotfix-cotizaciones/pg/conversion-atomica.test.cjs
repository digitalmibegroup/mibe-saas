'use strict';
/* Pruebas de convertir_cotizacion_atomica en un PostgreSQL TEMPORAL REAL (local, datos
   ficticios). Se llama a la funcion como rol anon, igual que lo hara el dashboard. */
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { disponible, iniciar, prepararBase, lit, RAIZ } = require('./pg-temporal.cjs');
const { COT, COT2, COT3, COT_OTRA, ANA, AJENO, VER, SEMILLA, FALLAS, clave, crearAyudas } = require('./comun.cjs');

let pg = null;
const SKIP = !disponible() && 'PostgreSQL portable no disponible';
const { llamada, convertir, fila, uno, foto, pool } = crearAyudas(() => pg);

before(() => { if (SKIP) return; pg = iniciar(); prepararBase(pg); const r = pg.sql(FALLAS); assert.ok(r.ok, r.err); });
after(() => { if (pg) pg.detener(); });
beforeEach(() => { if (pg) { const r = pg.sql(SEMILLA); assert.ok(r.ok, r.err); } });

test('instalación: DEFINER con dueño de privilegios mínimos, search_path fijo y registro cerrado a anon', { skip: SKIP }, () => {
  const f = fila(`SELECT p.proname, prosecdef, proconfig, proowner::regrole::text AS dueno, has_function_privilege('public', p.oid, 'EXECUTE') AS publico,
                  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon, has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth
                  FROM pg_proc p WHERE proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info') ORDER BY 1`);
  assert.equal(f.length, 2);
  for (const x of f) { assert.equal(x.prosecdef, true); assert.deepEqual(x.proconfig, ['search_path=public, pg_temp']); assert.equal(x.dueno, 'cotconv_ejecutor'); assert.equal(x.publico, false); assert.equal(x.anon, true); assert.equal(x.auth, true); }
  const rol = fila(`SELECT rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolcanlogin, rolreplication FROM pg_roles WHERE rolname='cotconv_ejecutor'`)[0];
  assert.deepEqual(rol, { rolsuper: false, rolbypassrls: false, rolcreaterole: false, rolcreatedb: false, rolcanlogin: false, rolreplication: false });
  for (const r of ['anon', 'authenticated']) for (const p of ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'])
    assert.equal(uno(`SELECT has_table_privilege('${r}','public.cotizacion_conversiones','${p}')`), 'f', r + ' no debe tener ' + p);
  assert.equal(uno(`SELECT relrowsecurity FROM pg_class WHERE relname='cotizacion_conversiones'`), 't');
  for (const p of ['DELETE', 'TRUNCATE', 'UPDATE']) assert.equal(uno(`SELECT has_table_privilege('cotconv_ejecutor','public.cotizacion_conversiones','${p}')`), 'f');
  for (const t of ['ventas', 'detalle_ventas', 'cartera', 'cartera_abonos', 'cotizaciones', 'inventario', 'clientes_frecuentes'])
    for (const p of ['DELETE', 'TRUNCATE']) assert.equal(uno(`SELECT has_table_privilege('cotconv_ejecutor','public.${t}','${p}')`), 'f', p + ' en ' + t);
  assert.equal(uno(`SELECT string_agg(a.attname, ',' ORDER BY a.attname) FROM pg_attribute a WHERE a.attrelid='public.inventario'::regclass AND a.attnum>0 AND has_column_privilege('cotconv_ejecutor',a.attrelid,a.attnum,'UPDATE')`), 'stock,uds_sueltas');
  assert.equal(uno(`SELECT has_table_privilege('cotconv_ejecutor','public.clientes_frecuentes','INSERT') OR has_table_privilege('cotconv_ejecutor','public.clientes_frecuentes','UPDATE')`), 'f');
  assert.equal(uno(`SELECT count(*) FROM pg_policies WHERE policyname LIKE 'anon\\_all\\_%'`), '7', 'las políticas de anon no cambiaron');
});

test('contado en efectivo: venta, detalle, empaques, inventario y vínculo en una transacción', { skip: SKIP }, () => {
  const r = convertir({});
  assert.ok(r.ok, r.err);
  assert.equal(r.json.estado, 'completada'); assert.equal(r.json.repetida, false); assert.equal(Number(r.json.total), 235000);
  const v = fila(`SELECT * FROM ventas WHERE cotizacion_id='${COT}'`);
  assert.equal(v.length, 1);
  assert.equal(v[0].metodo_pago, 'efectivo'); assert.equal(v[0].direccion_entrega, 'Calle 1 # 2-3'); assert.equal(v[0].detalle_entrega, 'Apto 101');
  assert.equal(v[0].cliente_nombre, 'Ana Pérez'); assert.equal(v[0].cliente_whatsapp, '3001112233');
  assert.equal(v[0].puntos_ganados, 0, 'la cotización tiene descuentos por línea');
  const d = fila(`SELECT prod_id, cantidad, es_unidad, uds_empaque, precio_unitario::float pu FROM detalle_ventas WHERE venta_id='${v[0].id}' ORDER BY prod_id, cantidad`);
  assert.deepEqual(d, [{ prod_id: 'cerveza6', cantidad: 1, es_unidad: false, uds_empaque: 6, pu: 55000 }, { prod_id: 'cerveza6', cantidad: 3, es_unidad: true, uds_empaque: 6, pu: 10000 }, { prod_id: 'ron', cantidad: 2, es_unidad: true, uds_empaque: 1, pu: 75000 }]);
  assert.equal(pool('cerveza6'), 53); assert.equal(uno(`SELECT stock||'/'||uds_sueltas FROM inventario WHERE id='cerveza6'`), '8/5');
  assert.equal(pool('ron'), 3);
  const c = fila(`SELECT estado, venta_id FROM cotizaciones WHERE id='${COT}'`)[0];
  assert.equal(c.estado, 'convertida'); assert.equal(c.venta_id, v[0].id);
  assert.equal(uno(`SELECT count(*) FROM cartera`), '0'); assert.equal(uno(`SELECT count(*) FROM cotizacion_conversiones`), '1');
});

test('transferencia: método y origen como en el POS', { skip: SKIP }, () => {
  const r = convertir({ pago: { tipo: 'transferencia', origen: 'Nequi' } });
  assert.ok(r.ok, r.err);
  const v = fila(`SELECT metodo_pago, notas, estado FROM ventas`)[0];
  assert.deepEqual(v, { metodo_pago: 'transferencia', notas: 'Origen: Nequi', estado: 'completada' });
});

test('crédito sin abono: cartera por el total y sin fila de abono', { skip: SKIP }, () => {
  const r = convertir({ pago: { tipo: 'credito', plazo: 15, abono: 0 } });
  assert.ok(r.ok, r.err);
  const v = fila(`SELECT estado, metodo_pago, abono::float, saldo_pendiente::float, puntos_ganados, fecha_vencimiento_cartera IS NOT NULL vence FROM ventas`)[0];
  assert.deepEqual(v, { estado: 'credito', metodo_pago: 'efectivo', abono: 0, saldo_pendiente: 235000, puntos_ganados: 0, vence: true });
  const c = fila(`SELECT total::float, saldo_pendiente::float, estado_cartera FROM cartera`)[0];
  assert.deepEqual(c, { total: 235000, saldo_pendiente: 235000, estado_cartera: 'activa' });
  assert.equal(uno(`SELECT count(*) FROM cartera_abonos`), '0');
});

test('crédito con abono: abono espejo compatible con registrar_abono_cartera_atomico de producción', { skip: SKIP }, () => {
  const r = convertir({ pago: { tipo: 'credito', plazo: 30, abono: 35000, medio_abono: 'transferencia', origen_abono: 'Nequi' } });
  assert.ok(r.ok, r.err);
  const v = fila(`SELECT estado, metodo_pago, notas, abono::float, saldo_pendiente::float FROM ventas`)[0];
  assert.deepEqual(v, { estado: 'credito', metodo_pago: 'transferencia', notas: 'Origen: Nequi', abono: 35000, saldo_pendiente: 200000 });
  const c = fila(`SELECT id, saldo_pendiente::float, fecha_creacion FROM cartera`)[0];
  const a = fila(`SELECT monto::float, medio_pago, registrado_por, fecha FROM cartera_abonos`)[0];
  assert.equal(a.monto, 35000); assert.equal(a.medio_pago, 'transferencia'); assert.equal(a.registrado_por, 'pos');
  assert.equal(a.fecha, c.fecha_creacion, 'misma fecha que la cartera');
  /* El siguiente abono con la RPC real de producción debe aceptarse (no "pendiente de conciliación") */
  const ab = pg.sql(`SELECT public.registrar_abono_cartera_atomico('${c.id}', 'lacava', 50000, now(), 'efectivo');`, { rol: 'anon' });
  assert.ok(ab.ok, ab.err);
  assert.equal(Number(uno(`SELECT saldo_pendiente FROM cartera`)), 150000);
});

test('abono que cubre el total: contado y puntos según las reglas del POS', { skip: SKIP }, () => {
  const r = convertir({ cot: COT2, pago: { tipo: 'credito', plazo: 30, abono: 80000, medio_abono: 'efectivo' } });
  assert.ok(r.ok, r.err);
  const v = fila(`SELECT estado, metodo_pago, abono::float, saldo_pendiente::float, puntos_ganados FROM ventas`)[0];
  assert.deepEqual(v, { estado: 'completada', metodo_pago: 'efectivo', abono: 0, saldo_pendiente: 0, puntos_ganados: 100 });
  assert.equal(uno(`SELECT count(*) FROM cartera`), '0');
});

test('puntos: crédito y ventas sin WhatsApp no generan puntos', { skip: SKIP }, () => {
  assert.ok(convertir({ cot: COT2, pago: { tipo: 'credito', plazo: 30 } }).ok);
  assert.equal(uno(`SELECT puntos_ganados FROM ventas`), '0');
  pg.sql(SEMILLA);
  pg.sql(`UPDATE cotizaciones SET cliente_whatsapp=NULL WHERE id='${COT2}'`);
  assert.ok(convertir({ cot: COT2, cliente: null, ver: uno(`SELECT updated_at FROM cotizaciones WHERE id='${COT2}'`) }).ok);
  assert.equal(uno(`SELECT puntos_ganados FROM ventas`), '0');
});

test('empaques y datos inválidos se rechazan sin modificar nada', { skip: SKIP }, () => {
  const casos = [
    [`UPDATE cotizaciones SET items='[{"prod_id":"cerveza6","nombre":"x","cantidad":1,"precio_unitario":60000,"precio_total":60000}]'`, 'CV036', /no indica si se cotizó/],
    [`UPDATE cotizaciones SET items='[{"prod_id":"ron","nombre":"x","cantidad":1,"precio_unitario":80000,"precio_total":80000,"tipo":"emp"}]'`, 'CV036', /no tiene empaque/],
    [`UPDATE cotizaciones SET items='[{"prod_id":"ron","nombre":"x","cantidad":1.5,"precio_unitario":80000,"precio_total":120000,"tipo":"und"}]'`, 'CV033', /cantidad/],
    [`UPDATE cotizaciones SET items='[{"prod_id":"ron","nombre":"x","precio_unitario":80000,"precio_total":80000,"tipo":"und"}]'`, 'CV033', /cantidad/],
    [`UPDATE cotizaciones SET items='[{"prod_id":"zz","nombre":"x","cantidad":1,"precio_unitario":1,"precio_total":1,"tipo":"und"}]'`, 'CV032', /ya no existe/],
    [`UPDATE cotizaciones SET items='[{"prod_id":"ajeno","nombre":"x","cantidad":1,"precio_unitario":1,"precio_total":1,"tipo":"und"}]'`, 'CV032', /ya no existe/],
    [`UPDATE cotizaciones SET items='[{"nombre":"x","cantidad":1,"precio_unitario":1,"precio_total":1,"tipo":"und"}]'`, 'CV031', /no está vinculada/],
    [`UPDATE cotizaciones SET items='[{"prod_id":"ron","nombre":"x","cantidad":2,"precio_unitario":80000,"precio_total":100000,"tipo":"und"}]'`, 'CV034', /inconsistente/],
    [`UPDATE cotizaciones SET items='[{"prod_id":"ron","nombre":"x","cantidad":9,"precio_unitario":1,"precio_total":9,"tipo":"und"}]'`, 'CV037', /Stock insuficiente de Ron 750/],
    [`UPDATE cotizaciones SET items='[{"prod_id":"ron","nombre":"x","cantidad":1,"precio_unitario":1,"precio_total":1,"tipo":"caja"}]'`, 'CV036', /desconocido/],
    [`UPDATE cotizaciones SET items='[]'`, 'CV030', /no tiene productos/]
  ];
  for (const [prep, cod, re] of casos) {
    pg.sql(SEMILLA);
    assert.ok(pg.sql(prep + `, updated_at='${VER}' WHERE id='${COT}'`).ok);
    const antes = foto();
    const r = convertir({});
    assert.equal(r.ok, false, prep); assert.equal(r.codigo, cod, prep + ' → ' + r.err); assert.match(r.mensaje, re);
    assert.equal(foto(), antes, 'sin cambios: ' + prep);
  }
});

test('pago, cliente y licencia se validan en la base', { skip: SKIP }, () => {
  const casos = [
    [{ pago: { tipo: 'transferencia' } }, 'CV042'],
    [{ pago: { tipo: 'transferencia', origen: 'Banco inventado' } }, 'CV042'],
    [{ pago: { tipo: 'credito', plazo: 30 }, cliente: null }, 'CV045'],
    [{ pago: { tipo: 'credito', plazo: 0 } }, 'CV046'],
    [{ pago: { tipo: 'credito', plazo: '30' } }, 'CV046'],
    [{ pago: { tipo: 'credito', plazo: 30, abono: 999999, medio_abono: 'efectivo' } }, 'CV043'],
    [{ pago: { tipo: 'credito', plazo: 30, abono: -1 } }, 'CV043'],
    [{ pago: { tipo: 'credito', plazo: 30, abono: 1000 } }, 'CV044'],
    [{ pago: { tipo: 'credito', plazo: 30, abono: 1000, medio_abono: 'transferencia' } }, 'CV044'],
    [{ pago: { tipo: 'cheque' } }, 'CV040'],
    [{ cliente: AJENO }, 'CV041'],
    [{ lic: 'otra' }, 'CV010'],
    [{ cot: COT_OTRA }, 'CV010'],
    [{ ver: '2026-11-16T10:00:00.123457+00:00' }, 'CV012'],
    [{ pago: { tipo: 'efectivo', total_esperado: 1 } }, 'CV012'],
    [{ clave: 'conv-no-valida' }, 'CV002'],
    [{ entrega: { direccion: 'x'.repeat(301) } }, 'CV047']
  ];
  const antes = foto();
  for (const [args, cod] of casos) {
    const r = convertir(args);
    assert.equal(r.ok, false, JSON.stringify(args)); assert.equal(r.codigo, cod, JSON.stringify(args) + ' → ' + r.err);
  }
  assert.equal(foto(), antes);
});

test('cliente: con ficha, nombre y WhatsApp salen de la base; la cotización de otra licencia no se ve', { skip: SKIP }, () => {
  pg.sql(`UPDATE cotizaciones SET cliente_nombre='Nombre escrito a mano', cliente_whatsapp='3999999999' WHERE id='${COT}'`);
  pg.sql(`UPDATE cotizaciones SET updated_at='${VER}' WHERE id='${COT}'`);
  assert.ok(convertir({}).ok);
  const v = fila(`SELECT cliente_nombre, cliente_whatsapp FROM ventas`)[0];
  assert.deepEqual(v, { cliente_nombre: 'Ana Pérez', cliente_whatsapp: '3001112233' });
  assert.equal(uno(`SELECT cliente_nombre FROM cotizaciones WHERE id='${COT}'`), 'Ana Pérez');
});

test('reintento con la misma clave (respuesta perdida): devuelve el resultado confirmado sin duplicar', { skip: SKIP }, () => {
  const args = { clave: clave(), pago: { tipo: 'credito', plazo: 30, abono: 35000, medio_abono: 'efectivo' } };
  const r1 = convertir(args); assert.ok(r1.ok, r1.err);
  const despues = foto();
  const r2 = convertir(args); assert.ok(r2.ok, r2.err);
  assert.equal(r2.json.venta_id, r1.json.venta_id); assert.equal(r2.json.repetida, true);
  assert.equal(foto(), despues, 'el reintento no escribe nada');
});

test('clave reutilizada con datos distintos: se rechaza y no cambia nada', { skip: SKIP }, () => {
  const k = clave();
  assert.ok(convertir({ clave: k }).ok);
  const antes = foto();
  for (const otro of [{ pago: { tipo: 'transferencia', origen: 'Nequi' } }, { entrega: { direccion: 'Otra' } }, { cliente: null }, { cot: COT2 }]) {
    const r = convertir(Object.assign({ clave: k }, otro));
    assert.equal(r.codigo, 'CV020', JSON.stringify(otro) + ' → ' + r.err);
  }
  assert.equal(foto(), antes);
});

test('cotización ya convertida con otra clave: se rechaza', { skip: SKIP }, () => {
  assert.ok(convertir({}).ok);
  const antes = foto();
  const r = convertir({});
  assert.equal(r.codigo, 'CV011'); assert.equal(foto(), antes);
});

test('dos dispositivos a la vez con claves distintas: una sola venta y un solo descuento', { skip: SKIP }, async () => {
  const intentos = [];
  for (let i = 0; i < 6; i++) intentos.push(pg.sqlAsync(llamada({ pago: i % 2 ? { tipo: 'efectivo' } : { tipo: 'credito', plazo: 10 } }).sql, { rol: 'anon' }));
  const rs = await Promise.all(intentos);
  const ok = rs.filter(r => r.ok);
  assert.equal(ok.length, 1, rs.map(r => r.codigo || 'ok').join(','));
  assert.ok(rs.filter(r => !r.ok).every(r => ['CV011', 'CV050'].includes(r.codigo)), rs.map(r => r.codigo).join(','));
  assert.equal(uno(`SELECT count(*) FROM ventas`), '1'); assert.equal(pool('cerveza6'), 53); assert.equal(pool('ron'), 3);
});

test('dos dispositivos a la vez con la MISMA clave: ambos reciben la misma venta', { skip: SKIP }, async () => {
  const { sql } = llamada({ clave: clave() });
  const rs = await Promise.all([pg.sqlAsync(sql, { rol: 'anon' }), pg.sqlAsync(sql, { rol: 'anon' }), pg.sqlAsync(sql, { rol: 'anon' })]);
  assert.ok(rs.every(r => r.ok), rs.map(r => r.err).join(' | '));
  const ids = new Set(rs.map(r => JSON.parse(r.out.split('\n').pop()).venta_id));
  assert.equal(ids.size, 1); assert.equal(uno(`SELECT count(*) FROM ventas`), '1'); assert.equal(pool('cerveza6'), 53);
});

test('otra operación bloquea la cotización: espera acotada, error claro y sin cambios', { skip: SKIP }, async () => {
  const antes = foto();
  const bloqueo = pg.sqlAsync(`BEGIN; SELECT 1 FROM cotizaciones WHERE id='${COT}' FOR UPDATE; SELECT pg_sleep(3.5); COMMIT;`);
  await new Promise(r => setTimeout(r, 400));
  const r = await pg.sqlAsync(llamada({}).sql, { rol: 'anon' });
  await bloqueo;
  assert.equal(r.ok, false); assert.equal(r.codigo, 'CV050', r.err);
  assert.equal(foto(), antes);
});

for (const paso of ['ventas:INSERT', 'detalle_ventas:INSERT', 'inventario:UPDATE', 'cartera:INSERT', 'cartera_abonos:INSERT', 'cotizaciones:UPDATE', 'cotizacion_conversiones:INSERT']) {
  test(`fallo inyectado en ${paso}: se deshace todo y el reintento con la misma clave funciona`, { skip: SKIP }, () => {
    const args = { clave: clave(), pago: { tipo: 'credito', plazo: 30, abono: 35000, medio_abono: 'transferencia', origen_abono: 'Nequi' } };
    const antes = foto();
    const r = convertir(args, { antes: `SET prueba.fallar = '${paso}';\n` });
    assert.equal(r.ok, false); assert.equal(r.codigo, 'XX999', r.err);
    assert.equal(foto(), antes, 'ningún dato cambió');
    const r2 = convertir(args);
    assert.ok(r2.ok, r2.err); assert.equal(r2.json.repetida, false);
    assert.equal(uno(`SELECT count(*) FROM ventas`), '1'); assert.equal(uno(`SELECT count(*) FROM cartera_abonos`), '1');
    assert.equal(pool('cerveza6'), 53); assert.equal(pool('ron'), 3);
  });
}

