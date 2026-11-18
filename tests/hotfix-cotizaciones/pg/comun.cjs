'use strict';
/* Datos ficticios y ayudas compartidas por las pruebas en PostgreSQL temporal. */
const assert = require('node:assert/strict');
const { lit } = require('./pg-temporal.cjs');

const COT = 'c0c0c0c0-0000-4000-8000-000000000001';   /* con descuentos por linea */
const COT2 = 'c0c0c0c0-0000-4000-8000-000000000002';  /* sin descuentos */
const COT3 = 'c0c0c0c0-0000-4000-8000-000000000003';  /* antigua sin tipo en producto x6 */
const COT_OTRA = 'c0c0c0c0-0000-4000-8000-000000000009'; /* de otra licencia */
const ANA = '11111111-1111-4111-8111-111111111111';
const AJENO = '99999999-9999-4999-8999-999999999999';
const VER = '2026-11-16T10:00:00.123456+00:00';
const TABLAS = ['inventario', 'clientes_frecuentes', 'ventas', 'detalle_ventas', 'cotizaciones', 'cartera', 'cartera_abonos', 'cotizacion_conversiones'];

const SEMILLA = `
SET session_replication_role = replica;
TRUNCATE cotizacion_conversiones, cartera_abonos, cartera, detalle_ventas, ventas, cotizaciones, clientes_frecuentes, inventario CASCADE;
INSERT INTO inventario (id,nombre,categoria,precio_venta,stock,uds_sueltas,uds_empaque,id_licencia) VALUES
 ('cerveza6','Cerveza x6','Cervezas',60000,10,2,6,'lacava'),('ron','Ron 750','Licores',80000,5,0,1,'lacava'),
 ('ajeno','Producto de otra licencia','X',1000,50,0,1,'otra');
INSERT INTO clientes_frecuentes (id,nombre,whatsapp,direccion,detalle,id_licencia) VALUES
 ('${ANA}','Ana Pérez','3001112233','Calle 1 # 2-3','Apto 101','lacava'),('${AJENO}','Cliente otra licencia','3000000000',NULL,NULL,'otra');
INSERT INTO cotizaciones (id,id_licencia,numero_local,numero,cliente_nombre,cliente_whatsapp,estado,items,total,fecha_creacion,updated_at) VALUES
 ('${COT}','lacava',1,7,'Ana Pérez','3001112233','aprobada','[
   {"prod_id":"cerveza6","nombre":"Cerveza x6","cantidad":3,"precio_unitario":10000,"precio_total":30000,"tipo":"und","_precioBase":10000,"descItem":0},
   {"prod_id":"cerveza6","nombre":"Cerveza x6 (Sixpack)","cantidad":1,"precio_unitario":55000,"precio_total":55000,"tipo":"emp","_precioBase":60000,"descItem":5000},
   {"prod_id":"ron","nombre":"Ron 750","cantidad":2,"precio_unitario":75000,"precio_total":150000,"tipo":"und","_precioBase":80000,"descItem":5000}]',235000,now(),'${VER}'),
 ('${COT2}','lacava',2,8,'Ana Pérez','3001112233','aprobada','[
   {"prod_id":"ron","nombre":"Ron 750","cantidad":1,"precio_unitario":80000,"precio_total":80000,"tipo":"und","_precioBase":80000,"descItem":0}]',80000,now(),'${VER}'),
 ('${COT3}','lacava',3,9,'Cliente sin ficha',NULL,'aprobada','[
   {"prod_id":"cerveza6","nombre":"Cerveza antigua","cantidad":1,"precio_unitario":60000,"precio_total":60000}]',60000,now(),'${VER}'),
 ('${COT_OTRA}','otra',4,1,'Otro','3000000000','aprobada','[
   {"prod_id":"ron","nombre":"Ron 750","cantidad":1,"precio_unitario":80000,"precio_total":80000,"tipo":"und"}]',80000,now(),'${VER}');
RESET session_replication_role;`;

/* Disparadores SOLO de prueba: provocan un error en un paso concreto de la funcion. */
const FALLAS = `
CREATE OR REPLACE FUNCTION public.prueba_falla() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('prueba.fallar', true) = TG_TABLE_NAME || ':' || TG_OP THEN
    RAISE EXCEPTION 'falla inyectada en %', TG_TABLE_NAME || ':' || TG_OP USING ERRCODE = 'XX999';
  END IF;
  RETURN NEW;
END $$;
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['ventas','detalle_ventas','inventario','cartera','cartera_abonos','cotizaciones','cotizacion_conversiones'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS prueba_falla_%1$s ON public.%1$I', t);
    EXECUTE format('CREATE TRIGGER prueba_falla_%1$s BEFORE INSERT OR UPDATE ON public.%1$I FOR EACH ROW EXECUTE FUNCTION public.prueba_falla()', t);
  END LOOP; END $$;`;

const clave = () => 'conv-' + require('node:crypto').randomUUID();
function crearAyudas(getPg) {
  const pg = { sql: (...a) => getPg().sql(...a), sqlAsync: (...a) => getPg().sqlAsync(...a) };
  function llamada(args) {
    const a = Object.assign({ lic: 'lacava', cot: COT, clave: clave(), ver: VER, pago: { tipo: 'efectivo' }, cliente: ANA, entrega: { direccion: 'Calle 1 # 2-3', detalle: 'Apto 101' } }, args);
    return { a, sql: `SELECT public.convertir_cotizacion_atomica(${lit(a.lic)}, ${lit(a.cot)}::uuid, ${lit(a.clave)}, ${lit(a.ver)}::timestamptz, ${lit(JSON.stringify(a.pago))}::jsonb, ${a.cliente ? lit(a.cliente) + '::uuid' : 'NULL'}, ${lit(JSON.stringify(a.entrega))}::jsonb);` };
  }
  function convertir(args, opc) {
    const { a, sql } = llamada(args);
    const r = pg.sql(sql, Object.assign({ rol: 'anon' }, opc));
    r.args = a; if (r.ok) r.json = JSON.parse(r.out.split('\n').pop());
    return r;
  }
  const fila = (q) => { const r = pg.sql(`SELECT row_to_json(x) FROM (${q}) x`); assert.ok(r.ok, r.err); return r.out ? r.out.split('\n').map(l => JSON.parse(l)) : []; };
  const uno = (q) => pg.sql(q).out;
  function foto() {
    return TABLAS.map(t => t + ':' + uno(`SELECT md5(COALESCE(string_agg(r::text, '|' ORDER BY r::text), '')) FROM (SELECT row_to_json(x) r FROM public.${t} x) z`)).join(' ');
  }
  const pool = (id) => Number(uno(`SELECT stock*uds_empaque+uds_sueltas FROM inventario WHERE id='${id}'`));
  return { llamada, convertir, fila, uno, foto, pool };
}
module.exports = { COT, COT2, COT3, COT_OTRA, ANA, AJENO, VER, TABLAS, SEMILLA, FALLAS, clave, crearAyudas };
