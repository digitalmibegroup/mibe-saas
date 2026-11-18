-- ENSAYO LOCAL sobre la copia restaurada de un respaldo de produccion (base desechable, SIN RED). Lo ejecuta ensayo-copia-respaldo.ps1.
-- Monta el repositorio en /h. Muestra: prechequeo, instalacion, verificador, intentos de reconvertir las cotizaciones convertidas
-- por el rol anon, y comparacion de huellas de las tablas antes y despues. Al final, pruebas de control del prechequeo (todas con ROLLBACK).
\set ON_ERROR_STOP on
\pset tuples_only on
\pset pager off
CREATE SCHEMA zz_ensayo;
CREATE TABLE zz_ensayo.snap (fase text, tabla text, huella text);
CREATE TABLE zz_ensayo.seq (fase text, valor bigint);
CREATE TABLE zz_ensayo.res (id uuid, prueba text, sqlstate text, mensaje text);
CREATE FUNCTION zz_ensayo.tomar(p_fase text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ventas','detalle_ventas','inventario','inventario_bodega','cartera','cartera_abonos','cotizaciones',
                           'clientes_frecuentes','puntos_clientes','puntos_transacciones','caja_sesiones','gastos','auditoria_eventos'] LOOP
    EXECUTE format('INSERT INTO zz_ensayo.snap SELECT %L, %L, md5(COALESCE(string_agg(x::text, ''|'' ORDER BY x::text), '''')) FROM public.%I x', p_fase, t, t);
  END LOOP;
  INSERT INTO zz_ensayo.seq SELECT p_fase, last_value FROM public.ventas_numero_venta_seq;
END $f$;

\echo === 1. PRECHEQUEO (antes de instalar)
\i /h/PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql
SELECT zz_ensayo.tomar('1_previo');

\echo === 2. INSTALACION del SQL de produccion
\i /h/HOTFIX_COT_CONVERSION_ATOMICA.sql
SELECT zz_ensayo.tomar('2_tras_instalar');
\echo === 3. VERIFICADOR
\i /h/HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql

\echo === 4. Intentos de reconvertir las cotizaciones del conjunto documentado, como anon (hasta 3 variantes cada una)
CREATE TABLE zz_ensayo.casos AS
  SELECT c.id FROM public.cotizaciones c JOIN public.ventas v ON v.id = c.venta_id
   WHERE c.estado = 'convertida' AND v.id_cliente = c.id_licencia AND v.cotizacion_id IS NULL;
DO $d$
DECLARE r record; v_j jsonb; v_mala text;
BEGIN
  FOR r IN SELECT c.id, c.id_licencia, c.updated_at, c.venta_id FROM public.cotizaciones c WHERE c.id IN (SELECT id FROM zz_ensayo.casos) ORDER BY c.id LOOP
    -- a) clave nueva, version correcta
    BEGIN
      SET LOCAL ROLE anon;
      PERFORM public.convertir_cotizacion_atomica(r.id_licencia, r.id, 'conv-' || gen_random_uuid(), r.updated_at,
                '{"tipo":"contado","metodo":"Efectivo"}'::jsonb, NULL, NULL);
      RESET ROLE;
      INSERT INTO zz_ensayo.res VALUES (r.id, 'a_clave_nueva', 'SIN_ERROR', 'SE CONVIRTIO (mal)');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO zz_ensayo.res VALUES (r.id, 'a_clave_nueva', SQLSTATE, SQLERRM);
    END;
    -- b) misma operacion repetida dos veces (idempotencia no debe abrir nada)
    FOR v_j IN SELECT to_jsonb('conv-' || gen_random_uuid()) FROM generate_series(1, 2) LOOP
      BEGIN
        SET LOCAL ROLE anon;
        PERFORM public.convertir_cotizacion_atomica(r.id_licencia, r.id, v_j #>> '{}', r.updated_at,
                  '{"tipo":"contado","metodo":"Efectivo"}'::jsonb, NULL, NULL);
        RESET ROLE;
        INSERT INTO zz_ensayo.res VALUES (r.id, 'b_repetida', 'SIN_ERROR', 'SE CONVIRTIO (mal)');
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO zz_ensayo.res VALUES (r.id, 'b_repetida', SQLSTATE, SQLERRM);
      END;
    END LOOP;
    -- c) diagnostico de solo lectura como anon
    BEGIN
      SET LOCAL ROLE anon;
      v_j := public.cotizacion_conversion_info(r.id_licencia, r.id);
      RESET ROLE;
      INSERT INTO zz_ensayo.res VALUES (r.id, 'c_info', 'OK', v_j::text);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO zz_ensayo.res VALUES (r.id, 'c_info', SQLSTATE, SQLERRM);
    END;
  END LOOP;
END $d$;
SELECT zz_ensayo.tomar('3_tras_intentos');

\echo === 5. RESULTADO DE LOS INTENTOS (prueba | sqlstate | cantidad)
SELECT prueba || ' | ' || sqlstate || ' | ' || count(*) || ' | ' || min(left(mensaje, 90)) FROM zz_ensayo.res GROUP BY prueba, sqlstate ORDER BY 1;
\echo === 5b. Cotizaciones del conjunto: siguen convertidas, con su venta existente, y el registro NO tiene filas nuevas
SELECT 'conjunto=' || count(*) || ' convertidas=' || count(*) FILTER (WHERE c.estado = 'convertida')
       || ' con_venta_existente=' || count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.ventas v WHERE v.id = c.venta_id))
       || ' mostradas_como_incompletas=' || count(*) FILTER (WHERE c.estado = 'convertida' AND c.venta_id IS NULL)
  FROM public.cotizaciones c WHERE c.id IN (SELECT id FROM zz_ensayo.casos);
SELECT 'registro_filas_nuevas=' || count(*) FROM public.cotizacion_conversiones WHERE cotizacion_id IN (SELECT id FROM zz_ensayo.casos);

\echo === 6. HUELLAS por tabla en las tres fases (debe haber UNA sola huella distinta por tabla)
SELECT tabla || ' | huellas_distintas=' || count(DISTINCT huella) || ' | ' || CASE WHEN count(DISTINCT huella) = 1 THEN 'IGUAL' ELSE 'CAMBIO' END
  FROM zz_ensayo.snap GROUP BY tabla ORDER BY tabla;
SELECT 'ventas_numero_venta_seq huellas_distintas=' || count(DISTINCT valor) || ' valor=' || min(valor) FROM zz_ensayo.seq;
SELECT 'DICTAMEN_NO_MODIFICA_DATOS|' || CASE WHEN (SELECT count(*) FROM (SELECT tabla FROM zz_ensayo.snap GROUP BY tabla HAVING count(DISTINCT huella) > 1) q) = 0
        AND (SELECT count(DISTINCT valor) FROM zz_ensayo.seq) = 1
        AND (SELECT count(*) FROM zz_ensayo.res WHERE sqlstate = 'SIN_ERROR') = 0
        AND (SELECT count(*) FROM zz_ensayo.res WHERE prueba IN ('a_clave_nueva','b_repetida') AND sqlstate <> 'CV011') = 0
      THEN 'CORRECTO' ELSE 'FALLA' END;

\echo === 7. CONTROLES DEL PRECHEQUEO (cada uno en una transaccion que se revierte)
\echo --- 7a. venta_id inexistente
BEGIN; ALTER TABLE public.cotizaciones DROP CONSTRAINT cotizaciones_venta_id_fkey;  -- la clave foranea lo impide; se quita solo dentro de esta prueba
UPDATE public.cotizaciones SET venta_id = gen_random_uuid() WHERE id = '71f5c2bf-386f-49fb-903d-077a6c4c9a5d';
\i /h/PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql
ROLLBACK;
\echo --- 7b. cotizacion convertida sin venta_id
BEGIN; UPDATE public.cotizaciones SET venta_id = NULL WHERE id = '71f5c2bf-386f-49fb-903d-077a6c4c9a5d';
\i /h/PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql
ROLLBACK;
\echo --- 7c. enlace contradictorio (la venta apunta a otra cotizacion)
BEGIN; UPDATE public.ventas SET cotizacion_id = (SELECT id FROM public.cotizaciones WHERE estado <> 'convertida' LIMIT 1)
 WHERE id = (SELECT venta_id FROM public.cotizaciones WHERE id = '71f5c2bf-386f-49fb-903d-077a6c4c9a5d');
\i /h/PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql
ROLLBACK;
\echo --- 7d. venta compartida por dos cotizaciones
BEGIN; UPDATE public.cotizaciones SET venta_id = (SELECT venta_id FROM public.cotizaciones WHERE id = '71f5c2bf-386f-49fb-903d-077a6c4c9a5d')
 WHERE id = '3c94d8e6-efea-4ecc-a19f-62f8f1bae070';
\i /h/PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql
ROLLBACK;
\echo --- 7e. dos ventas apuntan a la misma cotizacion
BEGIN; DROP INDEX public.idx_ventas_cotizacion_unica;  -- el indice unico lo impide; se quita solo dentro de esta prueba
UPDATE public.ventas SET cotizacion_id = (SELECT id FROM public.cotizaciones WHERE estado = 'convertida' AND id NOT IN (SELECT id FROM zz_ensayo.casos) LIMIT 1)
 WHERE id = (SELECT venta_id FROM public.cotizaciones WHERE id = '3c94d8e6-efea-4ecc-a19f-62f8f1bae070');
\i /h/PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql
ROLLBACK;
\echo --- 7f. una conversion fuera de la lista pierde su enlace inverso (11 casos)
BEGIN; UPDATE public.ventas SET cotizacion_id = NULL WHERE cotizacion_id = (SELECT id FROM public.cotizaciones WHERE estado = 'convertida' AND id NOT IN (SELECT id FROM zz_ensayo.casos) LIMIT 1);
\i /h/PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql
ROLLBACK;
\echo --- 7g. uno de los 10 recupera su enlace (9 casos): tampoco es conforme
BEGIN; UPDATE public.ventas SET cotizacion_id = '71f5c2bf-386f-49fb-903d-077a6c4c9a5d' WHERE id = (SELECT venta_id FROM public.cotizaciones WHERE id = '71f5c2bf-386f-49fb-903d-077a6c4c9a5d');
\i /h/PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql
ROLLBACK;
\echo --- 7h. sin cambios: de nuevo conforme
\i /h/PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql
