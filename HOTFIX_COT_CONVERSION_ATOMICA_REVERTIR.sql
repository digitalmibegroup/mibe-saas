-- ============================================================================
-- HOTFIX COTIZACIONES — REVERSION de la conversion atomica (v2)
-- ============================================================================
-- NO aplicar en staging ni en produccion sin autorizacion expresa de Michel.
--
-- Condiciones:
--   1. ANTES de ejecutar, el sitio publicado debe volver a un frontend que NO llame a
--      convertir_cotizacion_atomica (si no, "Convertir en venta" respondera que la
--      conversion segura no esta instalada, sin escribir nada).
--   2. Siempre se retira la INSTALACION: las dos funciones, las politicas RLS del rol, sus
--      privilegios y el rol cotconv_ejecutor.
--   3. La EVIDENCIA depende de si ya se opero:
--        - Registro VACIO (nunca se convirtio nada): se elimina tambien la tabla
--          cotizacion_conversiones. Queda el sistema exactamente como antes.
--        - Registro CON operaciones: la tabla NO se elimina. Se conserva (sin privilegios
--          para anon/authenticated y CON su disparador de solo-añadir) y el script lo informa. Puede reinstalarse despues: el prechequeo del
--          instalador acepta una tabla existente con la estructura esperada.
--        - Para eliminarla a proposito (despues de respaldarla y con autorizacion aparte):
--          DROP TABLE public.cotizacion_conversiones;  (no lo hace este script)
--   4. Lo que NO se deshace (intencional): ventas, detalles, movimientos de inventario,
--      carteras y abonos creados por la funcion son operaciones reales y se conservan.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $rev$
DECLARE n bigint := 0; t text; rr record;
BEGIN
  IF to_regclass('public.cotizacion_conversiones') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM public.cotizacion_conversiones' INTO n;
  END IF;

  -- Funciones (dependen del rol y de la tabla)
  DROP FUNCTION IF EXISTS public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb);
  DROP FUNCTION IF EXISTS public.cotizacion_conversion_info(text,uuid);

  -- Politicas del rol
  FOREACH t IN ARRAY ARRAY['cotizaciones','clientes_frecuentes','inventario','ventas','detalle_ventas','cartera','cartera_abonos'] LOOP
    IF to_regclass('public.'||t) IS NOT NULL THEN
      EXECUTE format('DROP POLICY IF EXISTS cotconv_sel_%s ON public.%I', CASE t WHEN 'clientes_frecuentes' THEN 'clientes' WHEN 'detalle_ventas' THEN 'detalle' WHEN 'cartera_abonos' THEN 'abonos' ELSE t END, t);
      EXECUTE format('DROP POLICY IF EXISTS cotconv_ins_%s ON public.%I', CASE t WHEN 'detalle_ventas' THEN 'detalle' WHEN 'cartera_abonos' THEN 'abonos' ELSE t END, t);
      EXECUTE format('DROP POLICY IF EXISTS cotconv_upd_%s ON public.%I', t, t);
    END IF;
  END LOOP;
  IF to_regclass('public.cotizacion_conversiones') IS NOT NULL THEN
    DROP POLICY IF EXISTS cotconv_sel_registro ON public.cotizacion_conversiones;
    DROP POLICY IF EXISTS cotconv_ins_registro ON public.cotizacion_conversiones;
  END IF;

  -- Privilegios y rol
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cotconv_ejecutor') THEN
    -- Solo los objetos donde el rol tiene permisos (los que concedio el instalador). Un REVOKE ... ON ALL TABLES IN SCHEMA falla si alguna
    -- tabla del esquema no pertenece al administrador, aunque el rol no tenga nada en ella.
    FOR rr IN SELECT DISTINCT c.oid::regclass AS obj, (c.relkind = 'S') AS es_secuencia
                FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
               WHERE c.relnamespace = 'public'::regnamespace AND c.relacl IS NOT NULL AND a.grantee = 'cotconv_ejecutor'::regrole LOOP
      EXECUTE format('REVOKE ALL ON %s %s FROM cotconv_ejecutor', CASE WHEN rr.es_secuencia THEN 'SEQUENCE' ELSE 'TABLE' END, rr.obj);
    END LOOP;
    EXECUTE 'REVOKE ALL ON SCHEMA public FROM cotconv_ejecutor';
    EXECUTE 'DROP ROLE cotconv_ejecutor';
  END IF;

  -- Evidencia
  IF to_regclass('public.cotizacion_conversiones') IS NOT NULL THEN
    IF n = 0 THEN
      DROP TABLE public.cotizacion_conversiones;   -- sus disparadores se eliminan con ella
      DROP FUNCTION IF EXISTS public.cotconv_registro_inmutable();
      RAISE NOTICE 'Reversion completa: el registro estaba vacio y se elimino.';
    ELSE
      RAISE NOTICE 'Reversion de la instalacion: se CONSERVO public.cotizacion_conversiones con % operacion(es) registradas (evidencia), junto con su proteccion de solo-anadir. No se elimino la tabla.', n;
    END IF;
  ELSE
    DROP FUNCTION IF EXISTS public.cotconv_registro_inmutable();
  END IF;

  -- Verificacion
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info'))
     OR (to_regclass('public.cotizacion_conversiones') IS NULL AND EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname = 'cotconv_registro_inmutable'))
     OR EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cotconv_ejecutor')
     OR EXISTS (SELECT 1 FROM pg_policies WHERE policyname LIKE 'cotconv\_%') THEN
    RAISE EXCEPTION 'VERIFICACION: la reversion no quedo completa';
  END IF;
  IF n > 0 AND to_regclass('public.cotizacion_conversiones') IS NULL THEN
    RAISE EXCEPTION 'VERIFICACION: se perdio el registro con operaciones';
  END IF;
END $rev$;
COMMIT;
