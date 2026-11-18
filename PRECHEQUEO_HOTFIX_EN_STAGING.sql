-- ============================================================================
-- HOTFIX COTIZACIONES — PRECHEQUEO DE SOLO LECTURA PARA EL ENSAYO EN STAGING (v5 + H1)
-- ============================================================================
-- No escribe nada: una transaccion READ ONLY que termina en ROLLBACK (el lanzador ademas abre la sesion con
-- default_transaction_read_only=on). Devuelve solo metadatos y conteos, nunca datos de clientes.
-- Sirve para: (1) decidir si HOTFIX_COT_CONVERSION_ATOMICA.sql se puede instalar tal cual; (2) CAPTURAR el estado de
-- permisos y politicas que un ensayo con permisos temporales tendria que restaurar; (3) dejar una linea base.
-- Formato:  CATEGORIA|clave|valor   (una linea por dato). Termina con RESULTADO|OK.
-- ============================================================================
BEGIN TRANSACTION READ ONLY;

SELECT 'ESTADO|transaccion_solo_lectura|' || current_setting('transaction_read_only');
SELECT 'ESTADO|servidor|' || current_setting('server_version');
SELECT 'ESTADO|staging_marca|' || (to_regnamespace('staging_marca') IS NOT NULL);
SELECT 'ESTADO|h1_instalado|' || (to_regnamespace('app') IS NOT NULL AND to_regprocedure('app.licencia_actual()') IS NOT NULL);
SELECT 'ESTADO|compras_v5_instalado|' || (to_regprocedure('public.lacava_pagos_compras_version()') IS NOT NULL);
SELECT 'ESTADO|hotfix_instalado|' || (EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info')));

-- ---------------------------------------------------------------- quien instalaria
SELECT 'ROL|actual|' || current_user || '|super=' || rolsuper || '|createrole=' || rolcreaterole || '|createdb=' || rolcreatedb || '|bypassrls=' || rolbypassrls
  FROM pg_roles WHERE rolname = current_user;
SELECT 'ROL|miembro_de|' || COALESCE(string_agg(r.rolname, ',' ORDER BY r.rolname), '(ninguno)')
  FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid WHERE m.member = (SELECT oid FROM pg_roles WHERE rolname = current_user);
SELECT 'ROL|existe_cotconv_ejecutor|' || EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cotconv_ejecutor');
SELECT 'ESQUEMA|public|dueno=' || nspowner::regrole::text || '|acl=' || COALESCE(nspacl::text, '(por defecto)') FROM pg_namespace WHERE nspname = 'public';

-- ---------------------------------------------------------------- tablas que toca el hotfix: dueño, RLS, permisos
SELECT 'TABLA|' || t.t || '|existe=' || (c.oid IS NOT NULL) || '|dueno=' || COALESCE(c.relowner::regrole::text, '-') || '|rls=' || COALESCE(c.relrowsecurity::text, '-') || '|force=' || COALESCE(c.relforcerowsecurity::text, '-')
  FROM (VALUES ('cotizaciones'),('clientes_frecuentes'),('inventario'),('ventas'),('detalle_ventas'),('cartera'),('cartera_abonos'),('licencias'),('cotizacion_conversiones')) t(t)
  LEFT JOIN pg_class c ON c.relnamespace = 'public'::regnamespace AND c.relname = t.t ORDER BY t.t;
-- ACL exacta (para poder restaurar): una linea por tabla/secuencia con su aclitem[] actual ('(por defecto)' si es NULL)
SELECT 'ACL|' || c.relkind::text || '|' || c.relname || '|' || COALESCE(c.relacl::text, '(por defecto)')
  FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace
   AND c.relname IN ('cotizaciones','clientes_frecuentes','inventario','ventas','detalle_ventas','cartera','cartera_abonos','licencias','ventas_numero_venta_seq') ORDER BY c.relname;
SELECT 'ACL_FUNCION|' || p.oid::regprocedure::text || '|' || COALESCE(p.proacl::text, '(por defecto)')
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('registrar_abono_cartera_atomico','lacava_registrar_abono_cartera','convertir_cotizacion_atomica','cotizacion_conversion_info') ORDER BY 1;
SELECT 'POLITICA|' || tablename || '|' || policyname || '|' || cmd || '|' || array_to_string(roles, ',')
  FROM pg_policies WHERE schemaname = 'public'
   AND tablename IN ('cotizaciones','clientes_frecuentes','inventario','ventas','detalle_ventas','cartera','cartera_abonos','licencias','cotizacion_conversiones') ORDER BY 1;
SELECT 'DISPARADOR|' || c.relname || '|' || t.tgname || '|' || p.oid::regproc::text || '|habilitado=' || t.tgenabled::text
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_proc p ON p.oid = t.tgfoid
 WHERE NOT t.tgisinternal AND c.relnamespace = 'public'::regnamespace
   AND c.relname IN ('cotizaciones','clientes_frecuentes','inventario','ventas','detalle_ventas','cartera','cartera_abonos') ORDER BY 1;

-- ---------------------------------------------------------------- requisitos del instalador (los mismos de su PRECHEQUEO)
SELECT 'REQUISITO|columnas_que_faltan|' || COALESCE((SELECT string_agg(t || '.' || c, ',') FROM (VALUES
    ('cotizaciones','id'),('cotizaciones','id_licencia'),('cotizaciones','estado'),('cotizaciones','items'),('cotizaciones','venta_id'),('cotizaciones','updated_at'),
    ('cotizaciones','cliente_nombre'),('cotizaciones','cliente_whatsapp'),('ventas','cotizacion_id'),('ventas','direccion_entrega'),('ventas','detalle_entrega'),
    ('ventas','abono'),('ventas','saldo_pendiente'),('ventas','fecha_vencimiento_cartera'),('ventas','puntos_ganados'),('ventas','cliente_whatsapp'),
    ('detalle_ventas','es_unidad'),('detalle_ventas','uds_empaque'),('detalle_ventas','prod_id'),('inventario','stock'),('inventario','uds_sueltas'),
    ('inventario','uds_empaque'),('inventario','id_licencia'),('inventario','nombre'),('clientes_frecuentes','id_licencia'),('cartera','venta_id'),
    ('cartera','fecha_creacion'),('cartera_abonos','medio_pago'),('cartera_abonos','registrado_por')) x(t, c)
  WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = x.t AND column_name = x.c)), 'ninguna');
SELECT 'REQUISITO|idx_ventas_cotizacion_unica|' || EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'idx_ventas_cotizacion_unica');
SELECT 'REQUISITO|cartera_venta_id_unique|' || EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cartera_venta_id_unique');
SELECT 'REQUISITO|secuencia_ventas_numero_venta_seq|' || (to_regclass('public.ventas_numero_venta_seq') IS NOT NULL);
SELECT 'REQUISITO|inventario_sin_licencia|' || (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.inventario WHERE id_licencia IS NULL', false, true, '')))[1]::text;
SELECT 'COLISION|politicas_cotconv|' || (SELECT count(*) FROM pg_policies WHERE policyname LIKE 'cotconv\_%');
SELECT 'COLISION|funciones_hotfix|' || (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info','cotconv_registro_inmutable'));
SELECT 'COLISION|tabla_registro|' || (to_regclass('public.cotizacion_conversiones') IS NOT NULL);

-- ---------------------------------------------------------------- conteos y estado de los datos (sin contenido)
SELECT 'DATOS|' || t.t || '|' || CASE WHEN to_regclass('public.' || t.t) IS NULL THEN '(no existe)'
         ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.' || quote_ident(t.t), false, true, '')))[1]::text END
  FROM (VALUES ('cotizaciones'),('clientes_frecuentes'),('inventario'),('ventas'),('detalle_ventas'),('cartera'),('cartera_abonos'),('cotizacion_conversiones'),('auditoria_eventos')) t(t) ORDER BY t.t;
SELECT 'DATOS|cotizaciones_convertidas_sin_venta|' || (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.cotizaciones WHERE estado = ''convertida'' AND venta_id IS NULL', false, true, '')))[1]::text;
SELECT 'DATOS|ventas_con_cotizacion|' || (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.ventas WHERE cotizacion_id IS NOT NULL', false, true, '')))[1]::text;
SELECT 'H1|perfiles_activos|' || CASE WHEN to_regclass('app.perfiles_usuario') IS NULL THEN '(sin H1)'
         ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM app.perfiles_usuario WHERE activo', false, true, '')))[1]::text END;
SELECT 'H1|usuarios_auth|' || CASE WHEN to_regclass('auth.users') IS NULL THEN '(sin auth)'
         ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM auth.users', false, true, '')))[1]::text END;
-- Secuencias: se leen de la vista de catalogo, no se avanzan. El hotfix y v5 las consumen (no se pueden devolver).
SELECT 'SECUENCIA|' || sequencename || '|ultimo=' || COALESCE(last_value::text, '(sin usar)') FROM pg_sequences
 WHERE schemaname = 'public' AND sequencename IN ('ventas_numero_venta_seq', 'lacava_version_cambios') ORDER BY 1;

SELECT 'RESULTADO|OK';
ROLLBACK;
