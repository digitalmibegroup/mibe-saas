'use strict';
/* Integridad del registro de idempotencia (auditoria): PostgreSQL TEMPORAL REAL, datos
   ficticios, llamadas como rol anon.
   1) Una insercion directa no puede fabricar una confirmacion.
   2) Un reintento verifica el estado real (no devuelve un resultado guardado sin comprobar).
   3) Eliminar una venta por el flujo normal conserva la evidencia y el reintento NO recrea ni descuenta.
   4) La reversion conserva el registro si hay operaciones. */
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { disponible, iniciar, prepararBase, lit, RAIZ } = require('./pg-temporal.cjs');
const { COT, COT2, ANA, VER, SEMILLA, FALLAS, clave, crearAyudas } = require('./comun.cjs');

let pg = null;
const SKIP = !disponible() && 'PostgreSQL portable no disponible';
const { convertir, fila, uno, pool } = crearAyudas(() => pg);
const INSTALAR = path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA.sql');
const REVERTIR = path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql');
const VERIFICAR = path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql');
const NEGOCIO = ['inventario', 'clientes_frecuentes', 'ventas', 'detalle_ventas', 'cotizaciones', 'cartera', 'cartera_abonos'];
const huellaNegocio = () => NEGOCIO.map(t => uno(`SELECT md5(COALESCE(string_agg(r::text, '|' ORDER BY r::text), '')) FROM (SELECT row_to_json(x) r FROM public.${t} x) z`)).join(' ');
const registro = () => fila(`SELECT op_clave, cotizacion_id, venta_id FROM cotizacion_conversiones ORDER BY created_at`);
const instalada = () => uno(`SELECT count(*) FROM pg_proc WHERE proname='convertir_cotizacion_atomica'`) === '1';
const CREDITO = { tipo: 'credito', plazo: 30, abono: 35000, medio_abono: 'efectivo' };

before(() => { if (SKIP) return; pg = iniciar(); prepararBase(pg); assert.ok(pg.sql(FALLAS).ok); });
after(() => { if (pg) pg.detener(); });
beforeEach(() => {
  if (!pg) return;
  if (!instalada()) { pg.sql(`DROP TABLE IF EXISTS cotizacion_conversiones CASCADE`, { rol: 'supa_postgres' }); pg.archivo(INSTALAR); assert.ok(pg.sql(FALLAS).ok); }
  const r = pg.sql(SEMILLA); assert.ok(r.ok, r.err);
});

/* huella exacta que calcula la funcion (para fabricar a mano una fila "perfecta") */
const huellaSql = (a) => `md5(jsonb_build_object('licencia','lacava','cotizacion','${a.cot}'::uuid,'version','${VER}'::timestamptz,'pago','${JSON.stringify(a.pago)}'::jsonb,'cliente',${a.cliente ? "'" + a.cliente + "'::uuid" : 'NULL::uuid'},'entrega','${JSON.stringify(a.entrega)}'::jsonb)::text)`;

/* ===== 1. Insercion directa ===== */
for (const rol of ['anon', 'authenticated']) {
  test(`${rol}: ninguna operación directa sobre el registro (INSERT falso, SELECT, UPDATE, DELETE, TRUNCATE)`, { skip: SKIP }, () => {
    const k = clave(), antes = huellaNegocio();
    const falso = `INSERT INTO public.cotizacion_conversiones (op_clave,id_licencia,cotizacion_id,venta_id,huella,resultado)
                   VALUES ('${k}','lacava','${COT}','aaaaaaaa-0000-4000-8000-000000000001','x','{"ok":true}');`;
    for (const sql of [falso, `SELECT * FROM public.cotizacion_conversiones;`, `UPDATE public.cotizacion_conversiones SET huella='y';`, `DELETE FROM public.cotizacion_conversiones;`, `TRUNCATE public.cotizacion_conversiones;`]) {
      const r = pg.sql(sql, { rol });
      assert.equal(r.ok, false, sql); assert.equal(r.codigo, '42501', sql + ' → ' + r.err);
    }
    assert.equal(uno(`SELECT count(*) FROM cotizacion_conversiones`), '0'); assert.equal(huellaNegocio(), antes);
  });
}
test('tras la inserción falsa rechazada, la operación real con esa clave se procesa como nueva y se verifica en el reintento', { skip: SKIP }, () => {
  const k = clave();
  const f = pg.sql(`INSERT INTO public.cotizacion_conversiones (op_clave,id_licencia,cotizacion_id,venta_id,huella,resultado) VALUES ('${k}','lacava','${COT}','aaaaaaaa-0000-4000-8000-000000000001','x','{"ok":true,"venta_id":"aaaaaaaa-0000-4000-8000-000000000001"}');`, { rol: 'anon' });
  assert.equal(f.codigo, '42501');
  const r1 = convertir({ clave: k }); assert.ok(r1.ok, r1.err);
  assert.equal(r1.json.repetida, false); assert.equal(pool('cerveza6'), 53);
  const r2 = convertir({ clave: k }); assert.ok(r2.ok, r2.err);
  assert.equal(r2.json.repetida, true); assert.equal(r2.json.verificada, true); assert.equal(r2.json.venta_id, r1.json.venta_id);
  assert.equal(registro().length, 1); assert.equal(uno(`SELECT count(*) FROM ventas`), '1'); assert.equal(pool('cerveza6'), 53);
});
test('defensa en profundidad: aunque un administrador fabricara la fila, el reintento no devuelve una confirmación falsa', { skip: SKIP }, () => {
  const k = clave(), a = { cot: COT, pago: { tipo: 'efectivo' }, cliente: ANA, entrega: { direccion: 'Calle 1 # 2-3', detalle: 'Apto 101' } };
  /* (a) fila perfecta (huella correcta) que apunta a una venta que NO existe */
  assert.ok(pg.sql(`SET session_replication_role = replica; INSERT INTO cotizacion_conversiones (op_clave,id_licencia,cotizacion_id,venta_id,huella,resultado)
     VALUES ('${k}','lacava','${COT}','bbbbbbbb-0000-4000-8000-000000000002',${huellaSql(a)},'{"ok":true}');`).ok);
  const antes = huellaNegocio();
  const r = convertir(Object.assign({ clave: k }, a));
  assert.equal(r.ok, false); assert.equal(r.codigo, 'CV022', r.err);
  assert.equal(huellaNegocio(), antes, 'no se creó venta ni se descontó inventario');
  /* (b) la venta existe pero la cotización NO está vinculada a ella */
  const k2 = clave();
  assert.ok(pg.sql(`SET session_replication_role = replica;
     INSERT INTO ventas (id,id_cliente,cliente_nombre,total,subtotal,metodo_pago,estado,cotizacion_id) VALUES ('cccccccc-0000-4000-8000-000000000003','lacava','Ana',235000,235000,'efectivo','completada','${COT}');
     INSERT INTO cotizacion_conversiones (op_clave,id_licencia,cotizacion_id,venta_id,huella,resultado) VALUES ('${k2}','lacava','${COT}','cccccccc-0000-4000-8000-000000000003',${huellaSql(a)},'{"ok":true}');`).ok);
  const antes2 = huellaNegocio();
  const r2 = convertir(Object.assign({ clave: k2 }, a));
  assert.equal(r2.ok, false); assert.equal(r2.codigo, 'CV023', r2.err); assert.match(r2.mensaje, /no está vinculada/);
  assert.equal(huellaNegocio(), antes2);
});

/* ===== 2. Verificacion del estado real en el reintento ===== */
test('reintento verificado: si el vínculo o la cartera cambiaron, se rechaza sin modificar nada', { skip: SKIP }, () => {
  const k = clave(), args = { clave: k, pago: CREDITO };
  assert.ok(convertir(args).ok);
  /* cotización desvinculada a mano */
  pg.sql(`UPDATE cotizaciones SET venta_id = NULL WHERE id='${COT}'`, { rol: 'anon' });
  let antes = huellaNegocio(), r = convertir(args);
  assert.equal(r.codigo, 'CV023', r.err); assert.equal(huellaNegocio(), antes);
  /* restaurar y borrar la cartera de un crédito */
  pg.sql(`UPDATE cotizaciones SET venta_id = (SELECT id FROM ventas WHERE cotizacion_id='${COT}') WHERE id='${COT}'`, { rol: 'anon' });
  pg.sql(`DELETE FROM cartera_abonos; DELETE FROM cartera;`, { rol: 'anon' });
  antes = huellaNegocio(); r = convertir(args);
  assert.equal(r.codigo, 'CV023', r.err); assert.match(r.mensaje, /falta la cartera/); assert.equal(huellaNegocio(), antes);
});
test('reintento verificado: la respuesta sale de los datos reales de la venta', { skip: SKIP }, () => {
  const k = clave(), args = { clave: k, pago: { tipo: 'transferencia', origen: 'Nequi' } };
  const r1 = convertir(args); assert.ok(r1.ok, r1.err);
  const r2 = convertir(args); assert.ok(r2.ok, r2.err);
  for (const c of ['venta_id', 'numero_venta', 'estado', 'metodo_pago', 'total', 'puntos_ganados']) assert.equal(String(r2.json[c]), String(r1.json[c]), c);
  assert.equal(r2.json.repetida, true); assert.equal(r2.json.verificada, true);
});

/* ===== 3. Venta eliminada por el flujo normal ===== */
/* Pasos de eliminarVenta() del dashboard: desvincular cotizacion (queda convertida con venta_id NULL),
   borrar detalle, borrar venta y restaurar stock. Todo como anon, igual que el navegador. */
function eliminarVentaFlujoNormal(ventaId) {
  const r = pg.sql(`
    UPDATE cotizaciones SET venta_id = NULL, estado = 'convertida', updated_at = now() WHERE venta_id = '${ventaId}';
    DELETE FROM detalle_ventas WHERE venta_id = '${ventaId}';
    DELETE FROM ventas WHERE id = '${ventaId}';
    UPDATE inventario SET stock = 10, uds_sueltas = 2 WHERE id = 'cerveza6';
    UPDATE inventario SET stock = 5, uds_sueltas = 0 WHERE id = 'ron';`, { rol: 'anon' });
  assert.ok(r.ok, r.err);
}
test('eliminar la venta convertida conserva la evidencia; el reintento devuelve un error claro y no recrea ni descuenta', { skip: SKIP }, () => {
  const k = clave();
  const r1 = convertir({ clave: k }); assert.ok(r1.ok, r1.err);
  assert.equal(pool('cerveza6'), 53);
  eliminarVentaFlujoNormal(r1.json.venta_id);
  assert.equal(uno(`SELECT count(*) FROM ventas`), '0');
  assert.equal(registro().length, 1, 'la evidencia sobrevive a la eliminación de la venta');
  assert.equal(registro()[0].venta_id, r1.json.venta_id);
  assert.equal(pool('cerveza6'), 62, 'stock restaurado por la eliminación'); assert.equal(pool('ron'), 5);
  const antes = huellaNegocio();
  const r2 = convertir({ clave: k });
  assert.equal(r2.ok, false); assert.equal(r2.codigo, 'CV022'); assert.match(r2.mensaje, /su venta fue eliminada\. No se recreó la venta ni se volvió a descontar inventario/);
  assert.equal(huellaNegocio(), antes, 'el reintento no escribió nada');
  assert.equal(uno(`SELECT count(*) FROM ventas`), '0'); assert.equal(pool('cerveza6'), 62);
  /* anon no puede borrar la evidencia, tampoco después */
  assert.equal(pg.sql(`DELETE FROM public.cotizacion_conversiones`, { rol: 'anon' }).codigo, '42501');
  const info = JSON.parse(uno(`SELECT public.cotizacion_conversion_info('lacava','${COT}')`));
  assert.equal(info.operaciones.length, 1); assert.equal(info.operaciones[0].venta_existe, false);
});
test('tras eliminar la venta y liberar la cotización, una operación NUEVA convierte; la antigua sigue sin poder reaparecer', { skip: SKIP }, () => {
  const k1 = clave(), k2 = clave();
  const r1 = convertir({ clave: k1 }); assert.ok(r1.ok);
  eliminarVentaFlujoNormal(r1.json.venta_id);
  /* liberación manual (decisión de Michel; fuera de este hotfix): vuelve a aprobada con una versión nueva */
  const nuevaVer = uno(`UPDATE cotizaciones SET estado='aprobada', updated_at='2026-11-17T08:00:00.000001+00:00' WHERE id='${COT}' RETURNING updated_at`).split('\n')[0];
  const r2 = convertir({ clave: k2, ver: nuevaVer }); assert.ok(r2.ok, r2.err);
  assert.notEqual(r2.json.venta_id, r1.json.venta_id); assert.equal(pool('cerveza6'), 53);
  assert.equal(registro().length, 2);
  const antiguo = convertir({ clave: k1 }); assert.equal(antiguo.codigo, 'CV022', 'la clave antigua no se apodera de la venta nueva');
  const repetido = convertir({ clave: k2, ver: nuevaVer }); assert.ok(repetido.ok, repetido.err);
  assert.equal(repetido.json.venta_id, r2.json.venta_id); assert.equal(repetido.json.repetida, true);
  assert.equal(uno(`SELECT count(*) FROM ventas`), '1'); assert.equal(pool('cerveza6'), 53, 'un solo descuento por la operación vigente');
});
test('el registro es de solo añadir incluso para el administrador (UPDATE, DELETE, TRUNCATE)', { skip: SKIP }, () => {
  assert.ok(convertir({}).ok);
  for (const sql of [`UPDATE public.cotizacion_conversiones SET huella='x'`, `DELETE FROM public.cotizacion_conversiones`, `TRUNCATE public.cotizacion_conversiones`]) {
    const r = pg.sql(sql, { rol: 'supa_postgres' });
    assert.equal(r.ok, false, sql); assert.equal(r.codigo, 'CV060', sql + ' → ' + r.err);
  }
  assert.equal(registro().length, 1);
});
test('operación sin dueño de la licencia: la evidencia de otra licencia no se ve ni se usa', { skip: SKIP }, () => {
  const k = clave();
  assert.ok(convertir({ clave: k }).ok);
  const r = convertir({ clave: k, lic: 'otra' });
  assert.ok(['CV010', 'CV020'].includes(r.codigo), r.err);
  assert.deepEqual(JSON.parse(uno(`SELECT public.cotizacion_conversion_info('otra','${COT}')`)), { operaciones: [] });
});

/* ===== 4. Reversion ===== */
function permisosAnonIntactos() {
  assert.equal(uno(`SELECT count(*) FROM pg_policies WHERE policyname LIKE 'anon\\_all\\_%'`), '7');
  for (const t of NEGOCIO) assert.equal(uno(`SELECT has_table_privilege('anon','public.${t}','SELECT,INSERT,UPDATE,DELETE')`), 't', t);
}
test('reversión ANTES de operar: retira todo (funciones, rol, políticas y registro) sin tocar el negocio', { skip: SKIP }, () => {
  const antes = huellaNegocio();
  const r = pg.archivoSeguro(REVERTIR); assert.ok(r.ok, r.err);
  assert.match(r.err, /el registro estaba vacio y se elimino/);
  assert.equal(uno(`SELECT count(*) FROM pg_proc WHERE proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info','cotconv_registro_inmutable')`), '0');
  assert.equal(uno(`SELECT count(*) FROM pg_roles WHERE rolname='cotconv_ejecutor'`), '0');
  assert.equal(uno(`SELECT count(*) FROM pg_policies WHERE policyname LIKE 'cotconv\\_%'`), '0');
  assert.equal(uno(`SELECT to_regclass('public.cotizacion_conversiones') IS NULL`), 't');
  assert.equal(huellaNegocio(), antes); permisosAnonIntactos();
  assert.equal(pg.sql(`SELECT public.convertir_cotizacion_atomica('lacava','${COT}','${clave()}',now(),'{}'::jsonb,NULL,'{}'::jsonb)`, { rol: 'anon' }).codigo, '42883');
  const v = pg.archivoSeguro(VERIFICAR); assert.ok(v.ok, v.err);
  assert.match(v.out, /RESULTADO\|NO_INSTALADO/); assert.doesNotMatch(v.out, /^ERROR\|/m);
});
test('reversión DESPUÉS de operar: conserva el registro y su protección; reinstalar recupera los reintentos', { skip: SKIP }, () => {
  const k = clave(), args = { clave: k, pago: CREDITO };
  const r1 = convertir(args); assert.ok(r1.ok, r1.err);
  const antes = huellaNegocio();
  const rev = pg.archivoSeguro(REVERTIR); assert.ok(rev.ok, rev.err);
  assert.match(rev.err, /se CONSERVO public\.cotizacion_conversiones con 1 operacion/);
  assert.equal(uno(`SELECT count(*) FROM pg_proc WHERE proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info')`), '0');
  assert.equal(uno(`SELECT count(*) FROM pg_roles WHERE rolname='cotconv_ejecutor'`), '0');
  assert.equal(uno(`SELECT count(*) FROM pg_policies WHERE policyname LIKE 'cotconv\\_%'`), '0');
  assert.equal(registro().length, 1, 'el registro con operaciones NO se elimina');
  assert.equal(huellaNegocio(), antes, 'ventas, cartera e inventario se conservan'); permisosAnonIntactos();
  for (const p of ['SELECT', 'INSERT', 'UPDATE', 'DELETE']) assert.equal(uno(`SELECT has_table_privilege('anon','public.cotizacion_conversiones','${p}')`), 'f');
  assert.equal(pg.sql(`DELETE FROM public.cotizacion_conversiones`, { rol: 'supa_postgres' }).codigo, 'CV060', 'la protección de solo-añadir se conserva');
  assert.equal(pg.sql(`SELECT public.convertir_cotizacion_atomica('lacava','${COT}','${k}',now(),'{}'::jsonb,NULL,'{}'::jsonb)`, { rol: 'anon' }).codigo, '42883');
  const v = pg.archivoSeguro(VERIFICAR); assert.ok(v.ok, v.err);
  assert.match(v.out, /RESULTADO\|NO_INSTALADO/); assert.match(v.out, /REGISTRO\|operaciones=1/); assert.doesNotMatch(v.out, /^ERROR\|/m);
  /* reinstalación: reutiliza el registro y el reintento de la misma operación se verifica sin escribir */
  const inst = pg.archivoSeguro(INSTALAR); assert.ok(inst.ok, inst.err); assert.match(inst.err, /se reutiliza el registro existente/);
  assert.ok(pg.sql(FALLAS).ok);
  const antes2 = huellaNegocio();
  const r2 = convertir(args); assert.ok(r2.ok, r2.err);
  assert.equal(r2.json.repetida, true); assert.equal(r2.json.venta_id, r1.json.venta_id);
  assert.equal(huellaNegocio(), antes2); assert.equal(registro().length, 1); assert.equal(pool('cerveza6'), 53);
});
test('reversión con una venta ya eliminada: el registro sobrevive y tras reinstalar el reintento sigue siendo CV022', { skip: SKIP }, () => {
  const k = clave();
  const r1 = convertir({ clave: k }); assert.ok(r1.ok);
  eliminarVentaFlujoNormal(r1.json.venta_id);
  assert.ok(pg.archivoSeguro(REVERTIR).ok); assert.equal(registro().length, 1);
  assert.ok(pg.archivoSeguro(INSTALAR).ok); assert.ok(pg.sql(FALLAS).ok);
  const antes = huellaNegocio();
  assert.equal(convertir({ clave: k }).codigo, 'CV022'); assert.equal(huellaNegocio(), antes);
});
test('la instalación es todo o nada: un fallo a mitad no deja rol, políticas ni funciones', { skip: SKIP }, () => {
  assert.ok(pg.archivoSeguro(REVERTIR).ok);
  /* una política con el mismo nombre hace fallar el script DESPUÉS de crear rol y tabla */
  assert.ok(pg.sql(`CREATE POLICY cotconv_sel_ventas ON public.ventas FOR SELECT TO anon USING (true)`, { rol: 'supa_postgres' }).ok);
  const inst = pg.archivoSeguro(INSTALAR);
  assert.equal(inst.ok, false); assert.match(inst.err, /cotconv_sel_ventas/);
  assert.equal(uno(`SELECT count(*) FROM pg_roles WHERE rolname='cotconv_ejecutor'`), '0', 'sin rol');
  assert.equal(uno(`SELECT to_regclass('public.cotizacion_conversiones') IS NULL`), 't', 'sin tabla');
  assert.equal(uno(`SELECT count(*) FROM pg_proc WHERE proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info')`), '0');
  assert.equal(uno(`SELECT count(*) FROM pg_policies WHERE policyname LIKE 'cotconv\\_%' AND policyname <> 'cotconv_sel_ventas'`), '0');
  pg.sql(`DROP POLICY cotconv_sel_ventas ON public.ventas`, { rol: 'supa_postgres' });
});
test('el prechequeo rechaza una instalación previa o un registro con otra estructura', { skip: SKIP }, () => {
  const dos = pg.archivoSeguro(INSTALAR);
  assert.equal(dos.ok, false); assert.match(dos.err, /PRECHEQUEO: el rol cotconv_ejecutor ya existe/);
  assert.ok(pg.archivoSeguro(REVERTIR).ok);
  assert.ok(pg.sql(`CREATE TABLE public.cotizacion_conversiones (x int)`, { rol: 'supa_postgres' }).ok);
  const otra = pg.archivoSeguro(INSTALAR);
  assert.equal(otra.ok, false); assert.match(otra.err, /existe con otra estructura/);
  assert.equal(uno(`SELECT count(*) FROM pg_roles WHERE rolname='cotconv_ejecutor'`), '0');
});
test('verificación de solo lectura: instalada no reporta errores y no cambia nada', { skip: SKIP }, () => {
  assert.ok(convertir({}).ok);
  const antes = huellaNegocio() + registro().length;
  const v = pg.archivoSeguro(VERIFICAR); assert.ok(v.ok, v.err);
  assert.match(v.out, /RESULTADO\|INSTALADO/); assert.doesNotMatch(v.out, /^ERROR\|/m);
  assert.match(v.out, /PRIVILEGIO\|anon\|cotizacion_conversiones\|$/m, 'anon sin privilegios sobre el registro');
  assert.match(v.out, /PRIVILEGIO\|authenticated\|cotizacion_conversiones\|$/m);
  assert.match(v.out, /FUNCION\|convertir_cotizacion_atomica.*definer=true\|dueno=cotconv_ejecutor/);
  assert.equal(huellaNegocio() + registro().length, antes);
});
