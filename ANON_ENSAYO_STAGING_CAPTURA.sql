-- ============================================================================
-- ENSAYO ANON EN STAGING (ca10112ba2) — CAPTURA DE ACL Y POLITICAS (SOLO LECTURA)
-- ============================================================================
-- Foto exacta, de TODO el esquema public, de los permisos y politicas que la fase anon puede tocar y de lo que debe
-- seguir igual: ACL de relaciones (tablas y secuencias) con RLS/FORCE, ACL de columnas, politicas completas
-- (roles, USING y WITH CHECK), ACL de funciones, privilegios por defecto y el USAGE de anon en los esquemas.
-- Una transaccion READ ONLY que termina en ROLLBACK. No lee datos de negocio. Formato: CAPT|tipo|...  (una linea por objeto,
-- en orden estable). Se ejecuta antes de abrir, despues de abrir y despues de restaurar; antes y despues deben ser IGUALES.
-- ============================================================================
BEGIN TRANSACTION READ ONLY;
SELECT 'CAPT|esquema|' || n.nspname || '|dueno=' || n.nspowner::regrole::text || '|acl=' || COALESCE(n.nspacl::text, '(defecto)')
  FROM pg_namespace n WHERE n.nspname IN ('public', 'app') ORDER BY n.nspname;
SELECT 'CAPT|relacion|' || c.relkind::text || '|' || c.relname || '|dueno=' || c.relowner::regrole::text || '|acl=' || COALESCE(c.relacl::text, '(defecto)')
       || '|rls=' || c.relrowsecurity::text || '|force=' || c.relforcerowsecurity::text
  FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
  ORDER BY c.relkind, c.relname;
SELECT 'CAPT|columna|' || c.relname || '.' || a.attname || '|acl=' || a.attacl::text
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
  WHERE c.relnamespace = 'public'::regnamespace AND a.attacl IS NOT NULL AND NOT a.attisdropped ORDER BY c.relname, a.attname;
SELECT 'CAPT|politica|' || p.tablename || '|' || p.policyname || '|' || p.permissive || '|roles=' || array_to_string(p.roles, ',') || '|' || p.cmd
       || '|using=' || COALESCE(regexp_replace(p.qual, '\s+', ' ', 'g'), '') || '|check=' || COALESCE(regexp_replace(p.with_check, '\s+', ' ', 'g'), '')
  FROM pg_policies p WHERE p.schemaname = 'public' ORDER BY p.tablename, p.policyname;
SELECT 'CAPT|funcion|' || p.oid::regprocedure::text || '|dueno=' || p.proowner::regrole::text || '|acl=' || COALESCE(p.proacl::text, '(defecto)')
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace ORDER BY p.oid::regprocedure::text;
SELECT 'CAPT|defecto|' || COALESCE(d.defaclnamespace::regnamespace::text, '(global)') || '|' || d.defaclrole::regrole::text || '|' || d.defaclobjtype::text || '|' || COALESCE(d.defaclacl::text, '')
  FROM pg_default_acl d ORDER BY d.defaclnamespace::regnamespace::text, d.defaclrole::regrole::text, d.defaclobjtype::text;
SELECT 'CAPT|anon_usage_public|' || has_schema_privilege('anon', 'public', 'USAGE')::text;
SELECT 'CAPT|anon_registro|' || concat_ws(',', CASE WHEN has_table_privilege('anon', 'public.cotizacion_conversiones', 'SELECT') THEN 'SELECT' END,
       CASE WHEN has_table_privilege('anon', 'public.cotizacion_conversiones', 'INSERT') THEN 'INSERT' END,
       CASE WHEN has_table_privilege('anon', 'public.cotizacion_conversiones', 'UPDATE') THEN 'UPDATE' END,
       CASE WHEN has_table_privilege('anon', 'public.cotizacion_conversiones', 'DELETE') THEN 'DELETE' END) WHERE to_regclass('public.cotizacion_conversiones') IS NOT NULL;
SELECT 'CAPT|fin';
ROLLBACK;
