-- ============================================================================
-- ENSAYO ANON EN STAGING (ca10112ba2) — APERTURA TEMPORAL Y MINIMA PARA LOS TRES FLUJOS
-- ============================================================================
-- Reproduce el acceso anonimo de produccion SOLO para: (1) crear cliente con direccion, (2) guardar y reabrir cotizacion,
-- (3) convertir en venta (contado y credito con abono). Conserva H1 y TODAS sus politicas: solo AGREGA permisos y politicas
-- ens_anon_* para el rol anon, que se retiran con ANON_ENSAYO_STAGING_RESTAURAR.sql.
-- Minimo necesario (mas estricto que el plan, que preveia FOR ALL en 8 tablas):
--   SELECT  : cotizaciones, clientes_frecuentes, inventario, ventas, detalle_ventas, cartera, cartera_abonos, licencias
--   INSERT  : cotizaciones, clientes_frecuentes        UPDATE: cotizaciones
--   EXECUTE : convertir_cotizacion_atomica, cotizacion_conversion_info  (hoy solo authenticated; produccion las concede a anon)
-- NO se concede: DELETE en nada, secuencias, caja, gastos, puntos, ventas en espera, el registro de idempotencia, ni
-- ningun permiso de escritura sobre inventario, ventas, detalle, cartera o abonos (la conversion escribe con el rol dueno).
-- Una sola transaccion: si algo falla, no queda nada.
-- ============================================================================
BEGIN;

DO $$
DECLARE t text;
BEGIN
  IF to_regclass('public.cotizacion_conversiones') IS NULL OR to_regprocedure('public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb)') IS NULL
     OR to_regprocedure('public.cotizacion_conversion_info(text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'APERTURA: el hotfix no esta instalado. No se hizo nada.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND policyname LIKE 'ens\_anon\_%') THEN
    RAISE EXCEPTION 'APERTURA: ya existen politicas ens_anon_* (apertura previa sin restaurar). No se hizo nada.';
  END IF;
  FOREACH t IN ARRAY ARRAY['cotizaciones','clientes_frecuentes','inventario','ventas','detalle_ventas','cartera','cartera_abonos','licencias','cotizacion_conversiones'] LOOP
    IF has_table_privilege('anon', 'public.' || t, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
      RAISE EXCEPTION 'APERTURA: anon ya tiene algun privilegio sobre %. No se hizo nada.', t; END IF;
  END LOOP;
  IF has_function_privilege('anon', 'public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cotizacion_conversion_info(text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'APERTURA: anon ya puede ejecutar una funcion del hotfix. No se hizo nada.'; END IF;
END $$;

GRANT SELECT ON public.cotizaciones, public.clientes_frecuentes, public.inventario, public.ventas, public.detalle_ventas,
                public.cartera, public.cartera_abonos, public.licencias TO anon;
GRANT INSERT ON public.cotizaciones, public.clientes_frecuentes TO anon;
GRANT UPDATE ON public.cotizaciones TO anon;

CREATE POLICY ens_anon_cotizaciones_sel      ON public.cotizaciones         FOR SELECT TO anon USING (true);
CREATE POLICY ens_anon_clientes_sel          ON public.clientes_frecuentes  FOR SELECT TO anon USING (true);
CREATE POLICY ens_anon_inventario_sel        ON public.inventario           FOR SELECT TO anon USING (true);
CREATE POLICY ens_anon_ventas_sel            ON public.ventas               FOR SELECT TO anon USING (true);
CREATE POLICY ens_anon_detalle_sel           ON public.detalle_ventas       FOR SELECT TO anon USING (true);
CREATE POLICY ens_anon_cartera_sel           ON public.cartera              FOR SELECT TO anon USING (true);
CREATE POLICY ens_anon_abonos_sel            ON public.cartera_abonos       FOR SELECT TO anon USING (true);
CREATE POLICY ens_anon_licencias_sel         ON public.licencias            FOR SELECT TO anon USING (true);
CREATE POLICY ens_anon_cotizaciones_ins      ON public.cotizaciones         FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY ens_anon_clientes_ins          ON public.clientes_frecuentes  FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY ens_anon_cotizaciones_upd      ON public.cotizaciones         FOR UPDATE TO anon USING (true) WITH CHECK (true);

DO $m$
BEGIN  -- membresia TEMPORAL en el rol dueno de las funciones (como el instalador): sin ella, GRANT/REVOKE EXECUTE de un no-dueno no hace nada
  IF current_setting('server_version_num')::int >= 160000 THEN EXECUTE format('GRANT cotconv_ejecutor TO %I WITH SET TRUE', current_user);
  ELSE EXECUTE format('GRANT cotconv_ejecutor TO %I', current_user); END IF;
END $m$;
SET LOCAL ROLE cotconv_ejecutor;
GRANT EXECUTE ON FUNCTION public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb),
                          public.cotizacion_conversion_info(text,uuid) TO anon;
RESET ROLE;
DO $rm$
BEGIN
  EXECUTE format('REVOKE cotconv_ejecutor FROM %I', current_user);
  IF EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.roleid = 'cotconv_ejecutor'::regrole AND m.member = current_user::regrole AND (m.inherit_option OR m.set_option)) THEN
    RAISE EXCEPTION 'quedo una membresia temporal en cotconv_ejecutor'; END IF;
END $rm$;

DO $$
BEGIN
  IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND policyname LIKE 'ens\_anon\_%') <> 11 THEN RAISE EXCEPTION 'APERTURA: se esperaban 11 politicas ens_anon_*'; END IF;
  IF has_table_privilege('anon', 'public.cotizacion_conversiones', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') THEN RAISE EXCEPTION 'APERTURA: el registro de idempotencia quedo abierto a anon'; END IF;
  IF has_table_privilege('anon', 'public.inventario', 'INSERT,UPDATE,DELETE') OR has_table_privilege('anon', 'public.ventas', 'INSERT,UPDATE,DELETE')
     OR has_table_privilege('anon', 'public.cartera', 'INSERT,UPDATE,DELETE') OR has_table_privilege('anon', 'public.cartera_abonos', 'INSERT,UPDATE,DELETE')
     OR has_table_privilege('anon', 'public.detalle_ventas', 'INSERT,UPDATE,DELETE') OR has_table_privilege('anon', 'public.licencias', 'INSERT,UPDATE,DELETE')
     OR has_table_privilege('anon', 'public.clientes_frecuentes', 'UPDATE,DELETE') OR has_table_privilege('anon', 'public.cotizaciones', 'DELETE') THEN
    RAISE EXCEPTION 'APERTURA: anon quedo con mas permisos de los previstos'; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND policyname LIKE 'h1\_%') < 1 THEN RAISE EXCEPTION 'APERTURA: no se ven las politicas de H1'; END IF;
END $$;
COMMIT;
