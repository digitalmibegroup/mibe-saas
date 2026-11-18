-- HOTFIX COTIZACIONES — VERIFICACION en UNA sola tabla de resultados (SOLO LECTURA).
-- Mismas consultas que HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql (generado por tests/hotfix-cotizaciones/ensayo/generar-verificar-una-tabla.cjs),
-- reunidas en una unica instruccion porque el SQL Editor de Supabase solo muestra el resultado de la ultima. Un solo SELECT: no escribe nada.
-- Cada linea empieza por su categoria; "ERROR|..." indica un incumplimiento. La ultima linea es RESULTADO|INSTALADO o RESULTADO|NO_INSTALADO.
WITH s1 AS (
SELECT 'FUNCION|' || p.oid::regprocedure::text || '|definer=' || p.prosecdef || '|dueno=' || p.proowner::regrole::text
       || '|config=' || COALESCE(array_to_string(p.proconfig, ','), '-')
       || '|anon_exec=' || has_function_privilege('anon', p.oid, 'EXECUTE') || '|auth_exec=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
       || '|public_exec=' || has_function_privilege('public', p.oid, 'EXECUTE')
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info') ORDER BY 1
),
s2 AS (
SELECT 'ROL|' || rolname || '|login=' || rolcanlogin || '|super=' || rolsuper || '|bypassrls=' || rolbypassrls
       || '|createrole=' || rolcreaterole || '|createdb=' || rolcreatedb || '|replic=' || rolreplication
  FROM pg_roles WHERE rolname = 'cotconv_ejecutor'
),
s3 AS (
SELECT 'PRIVILEGIO|' || r.rol || '|' || t.tabla || '|' || CASE WHEN to_regclass('public.' || t.tabla) IS NULL THEN '(tabla ausente)' ELSE array_to_string(ARRAY(
         SELECT p FROM unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE']) p WHERE has_table_privilege(r.rol, 'public.' || t.tabla, p)), ',') END
  FROM (VALUES ('anon'),('authenticated'),('cotconv_ejecutor')) r(rol)
  CROSS JOIN (VALUES ('cotizacion_conversiones'),('ventas'),('detalle_ventas'),('cotizaciones'),('inventario'),('cartera'),('cartera_abonos'),('clientes_frecuentes')) t(tabla)
 WHERE r.rol <> 'cotconv_ejecutor' OR EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cotconv_ejecutor')
 ORDER BY r.rol, t.tabla
),
s4 AS (
SELECT 'COLUMNAS_ESCRIBIBLES|cotconv_ejecutor|' || c.relname || '|' || string_agg(a.attname, ',' ORDER BY a.attname)
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
 WHERE c.relnamespace = 'public'::regnamespace AND c.relname IN ('cotizaciones','inventario') AND a.attnum > 0 AND NOT a.attisdropped
   AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cotconv_ejecutor') AND has_column_privilege('cotconv_ejecutor', c.oid, a.attnum, 'UPDATE')
 GROUP BY c.relname
),
s5 AS (
SELECT 'RLS|' || c.relname || '|activa=' || c.relrowsecurity FROM pg_class c
 WHERE c.relnamespace = 'public'::regnamespace AND c.relname IN ('cotizacion_conversiones','ventas','detalle_ventas','cotizaciones','inventario','cartera','cartera_abonos','clientes_frecuentes') ORDER BY 1
),
s6 AS (
SELECT 'POLITICA|' || tablename || '|' || policyname || '|' || cmd || '|' || array_to_string(roles, ',')
  FROM pg_policies WHERE schemaname = 'public' AND (policyname LIKE 'cotconv\_%' OR tablename = 'cotizacion_conversiones') ORDER BY 1
),
s7 AS (
SELECT 'DISPARADOR|' || tgname || '|' || tgrelid::regclass::text FROM pg_trigger WHERE tgrelid = to_regclass('public.cotizacion_conversiones') AND NOT tgisinternal ORDER BY 1
),
s8 AS (
SELECT 'REGISTRO|operaciones=' || (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.cotizacion_conversiones', false, true, '')))[1]::text
       || '|con_venta_eliminada=' || (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.cotizacion_conversiones c WHERE NOT EXISTS (SELECT 1 FROM public.ventas v WHERE v.id = c.venta_id)', false, true, '')))[1]::text
 WHERE to_regclass('public.cotizacion_conversiones') IS NOT NULL
),
s9 AS (
SELECT 'ERROR|' || msg FROM (
  SELECT 'anon/authenticated tienen privilegios sobre cotizacion_conversiones' AS msg
   WHERE CASE WHEN to_regclass('public.cotizacion_conversiones') IS NULL THEN false ELSE (
     has_table_privilege('anon', 'public.cotizacion_conversiones', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
     OR has_table_privilege('authenticated', 'public.cotizacion_conversiones', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')) END
  UNION ALL SELECT 'una funcion del hotfix no es SECURITY DEFINER con dueno cotconv_ejecutor y search_path fijo'
   WHERE EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info')
                  AND (NOT p.prosecdef OR p.proowner::regrole::text <> 'cotconv_ejecutor' OR NOT COALESCE(p.proconfig @> ARRAY['search_path=public, pg_temp'], false)))
  UNION ALL SELECT 'PUBLIC puede ejecutar una funcion del hotfix'
   WHERE EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info') AND has_function_privilege('public', p.oid, 'EXECUTE'))
  UNION ALL SELECT 'cotconv_ejecutor tiene DELETE o TRUNCATE sobre una tabla'
   WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cotconv_ejecutor') AND EXISTS (SELECT 1 FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
                  AND (has_table_privilege('cotconv_ejecutor', c.oid, 'DELETE') OR has_table_privilege('cotconv_ejecutor', c.oid, 'TRUNCATE')))
  UNION ALL SELECT 'cotconv_ejecutor es superusuario, ignora RLS, puede crear roles o iniciar sesion'
   WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cotconv_ejecutor' AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolcanlogin OR rolreplication))
) e
),
s10 AS (
SELECT 'RESULTADO|' || CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'convertir_cotizacion_atomica') THEN 'INSTALADO' ELSE 'NO_INSTALADO' END
)
SELECT linea FROM (
SELECT 1 AS o, s1.* FROM s1
UNION ALL
SELECT 2 AS o, s2.* FROM s2
UNION ALL
SELECT 3 AS o, s3.* FROM s3
UNION ALL
SELECT 4 AS o, s4.* FROM s4
UNION ALL
SELECT 5 AS o, s5.* FROM s5
UNION ALL
SELECT 6 AS o, s6.* FROM s6
UNION ALL
SELECT 7 AS o, s7.* FROM s7
UNION ALL
SELECT 8 AS o, s8.* FROM s8
UNION ALL
SELECT 9 AS o, s9.* FROM s9
UNION ALL
SELECT 10 AS o, s10.* FROM s10
) u(o, linea) ORDER BY o, linea;
