-- ============================================================================
-- ENSAYO ANON EN STAGING (ca10112ba2) — RESTAURACION EXACTA
-- ============================================================================
-- Deshace SOLO lo de ANON_ENSAYO_STAGING_ABRIR.sql: retira todo privilegio de anon sobre las 8 tablas, borra las politicas
-- ens_anon_* y retira EXECUTE de anon en las 2 funciones. Antes de la apertura anon no tenia nada de eso (la captura lo
-- demuestra: relacl sin entrada de anon, funciones solo para authenticated), asi que revocar deja el ACL como estaba.
-- El lanzador compara despues la captura completa con la de antes de abrir y detiene todo si hay diferencias.
-- Una sola transaccion; idempotente (se puede repetir sin efecto si ya esta restaurado).
-- ============================================================================
BEGIN;
REVOKE ALL ON public.cotizaciones, public.clientes_frecuentes, public.inventario, public.ventas, public.detalle_ventas,
              public.cartera, public.cartera_abonos, public.licencias FROM anon;
REVOKE ALL ON public.cotizacion_conversiones FROM anon;
DROP POLICY IF EXISTS ens_anon_cotizaciones_sel ON public.cotizaciones;
DROP POLICY IF EXISTS ens_anon_clientes_sel     ON public.clientes_frecuentes;
DROP POLICY IF EXISTS ens_anon_inventario_sel   ON public.inventario;
DROP POLICY IF EXISTS ens_anon_ventas_sel       ON public.ventas;
DROP POLICY IF EXISTS ens_anon_detalle_sel      ON public.detalle_ventas;
DROP POLICY IF EXISTS ens_anon_cartera_sel      ON public.cartera;
DROP POLICY IF EXISTS ens_anon_abonos_sel       ON public.cartera_abonos;
DROP POLICY IF EXISTS ens_anon_licencias_sel    ON public.licencias;
DROP POLICY IF EXISTS ens_anon_cotizaciones_ins ON public.cotizaciones;
DROP POLICY IF EXISTS ens_anon_clientes_ins     ON public.clientes_frecuentes;
DROP POLICY IF EXISTS ens_anon_cotizaciones_upd ON public.cotizaciones;
DO $m$
BEGIN  -- membresia TEMPORAL en el rol dueno de las funciones (como el instalador): sin ella, GRANT/REVOKE EXECUTE de un no-dueno no hace nada
  IF current_setting('server_version_num')::int >= 160000 THEN EXECUTE format('GRANT cotconv_ejecutor TO %I WITH SET TRUE', current_user);
  ELSE EXECUTE format('GRANT cotconv_ejecutor TO %I', current_user); END IF;
END $m$;
SET LOCAL ROLE cotconv_ejecutor;
REVOKE EXECUTE ON FUNCTION public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb),
                           public.cotizacion_conversion_info(text,uuid) FROM anon;
RESET ROLE;
DO $rm$
BEGIN
  EXECUTE format('REVOKE cotconv_ejecutor FROM %I', current_user);
  IF EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.roleid = 'cotconv_ejecutor'::regrole AND m.member = current_user::regrole AND (m.inherit_option OR m.set_option)) THEN
    RAISE EXCEPTION 'quedo una membresia temporal en cotconv_ejecutor'; END IF;
END $rm$;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND policyname LIKE 'ens\_anon\_%') THEN RAISE EXCEPTION 'RESTAURACION: quedan politicas ens_anon_*'; END IF;
  IF has_table_privilege('anon', 'public.cotizaciones', 'SELECT,INSERT,UPDATE,DELETE') OR has_table_privilege('anon', 'public.cotizacion_conversiones', 'SELECT,INSERT,UPDATE,DELETE')
     OR has_function_privilege('anon', 'public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cotizacion_conversion_info(text,uuid)', 'EXECUTE') THEN RAISE EXCEPTION 'RESTAURACION: anon conserva permisos'; END IF;
END $$;
COMMIT;
