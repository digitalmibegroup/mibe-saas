-- ============================================================================
-- INVENTARIO: ocultar productos — FOTO DE SOLO LECTURA DE STAGING (antes y despues de instalar o revertir)
-- ============================================================================
-- Una transaccion READ ONLY que termina en ROLLBACK. No lee datos de clientes: solo conteos, nombres de objetos, banderas y una huella md5 del inventario
-- SIN la columna "oculto" (para comprobar que instalar o revertir no cambia ningun dato). Formato:  CATEGORIA|clave|valor   Termina con RESULTADO|OK.
-- El lanzador compara la foto de antes con la de despues: solo pueden cambiar las lineas COLUMNA| y PRIVILEGIO|*_oculto.
-- ============================================================================
BEGIN TRANSACTION READ ONLY;
SELECT 'ESTADO|transaccion_solo_lectura|' || current_setting('transaction_read_only');
SELECT 'ESTADO|version_servidor|' || current_setting('server_version_num');
SELECT 'ESTADO|staging_marca|' || (to_regnamespace('staging_marca') IS NOT NULL);
SELECT 'TABLA|inventario_existe|' || (to_regclass('public.inventario') IS NOT NULL);
SELECT 'TABLA|inventario_dueno|' || c.relowner::regrole::text || '|usuario_es_dueno_o_miembro=' || pg_has_role(current_user, c.relowner, 'MEMBER')
  FROM pg_class c WHERE c.oid = 'public.inventario'::regclass;
SELECT 'TABLA|inventario_rls|' || c.relrowsecurity::text || '|force=' || c.relforcerowsecurity::text FROM pg_class c WHERE c.oid = 'public.inventario'::regclass;
SELECT 'COLUMNA|oculto_existe|' || EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'inventario' AND column_name = 'oculto');
SELECT 'COLUMNA|oculto_definicion|' || data_type || '|nullable=' || is_nullable || '|default=' || COALESCE(column_default, '(ninguno)')
  FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'inventario' AND column_name = 'oculto';
SELECT 'DATOS|inventario_filas|' || count(*) FROM public.inventario;
SELECT 'DATOS|inventario_huella_sin_oculto|' || COALESCE(md5(string_agg((to_jsonb(i) - 'oculto')::text, '|' ORDER BY i.id)), '(vacio)') FROM public.inventario i;
SELECT 'DATOS|inventario_bodega_filas|' || CASE WHEN to_regclass('public.inventario_bodega') IS NULL THEN '(no existe)'
  ELSE (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.inventario_bodega', false, true, '')))[1]::text END;
SELECT 'DATOS|bodegas_filas|' || CASE WHEN to_regclass('public.bodegas') IS NULL THEN '(no existe)'
  ELSE (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.bodegas', false, true, '')))[1]::text END;
SELECT 'ENSAYO|productos_ens_ocu|' || count(*) FROM public.inventario WHERE id LIKE 'ens-ocu-%';
SELECT 'ACL|inventario|' || COALESCE(c.relacl::text, '(defecto)') FROM pg_class c WHERE c.oid = 'public.inventario'::regclass;
SELECT 'ACL|columnas_con_acl_propia|' || count(*) FROM pg_attribute a WHERE a.attrelid = 'public.inventario'::regclass AND a.attacl IS NOT NULL AND NOT a.attisdropped AND a.attname <> 'oculto';
SELECT 'POLITICA|' || p.policyname || '|' || p.cmd::text || '|roles=' || array_to_string(p.roles, ',') FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = 'inventario' ORDER BY p.policyname;
SELECT 'DISPARADOR|' || t.tgname || '|habilitado=' || t.tgenabled::text FROM pg_trigger t WHERE t.tgrelid = 'public.inventario'::regclass AND NOT t.tgisinternal ORDER BY t.tgname;
SELECT 'PRIVILEGIO|' || r || '_tabla|' || concat_ws(',', CASE WHEN has_table_privilege(r, 'public.inventario', 'SELECT') THEN 'SELECT' END,
    CASE WHEN has_table_privilege(r, 'public.inventario', 'INSERT') THEN 'INSERT' END, CASE WHEN has_table_privilege(r, 'public.inventario', 'UPDATE') THEN 'UPDATE' END,
    CASE WHEN has_table_privilege(r, 'public.inventario', 'DELETE') THEN 'DELETE' END)
  FROM unnest(ARRAY['anon', 'authenticated']) AS r;
SELECT 'PRIVILEGIO|' || r || '_oculto|' || CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'inventario' AND column_name = 'oculto')
    THEN 'SELECT=' || has_column_privilege(r, 'public.inventario', 'oculto', 'SELECT')::text || ',UPDATE=' || has_column_privilege(r, 'public.inventario', 'oculto', 'UPDATE')::text
    ELSE '(sin columna)' END
  FROM unnest(ARRAY['anon', 'authenticated']) AS r;
SELECT 'RESULTADO|OK';
ROLLBACK;
