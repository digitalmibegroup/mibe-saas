-- ============================================================================
-- HOTFIX COTIZACIONES — LECTURA (SOLO LECTURA) DEL USUARIO CON PERFIL ACTIVO EN STAGING
-- ============================================================================
-- Devuelve el UUID EXACTO del usuario con perfil activo de H1, para restablecer solo su contrasena. No escribe nada:
-- una transaccion READ ONLY que termina en ROLLBACK. No lee contrasenas ni hashes. Solo identificadores, licencia y banderas.
-- Formato:  CATEGORIA|clave|valor   Termina con RESULTADO|OK.
-- ============================================================================
BEGIN TRANSACTION READ ONLY;
SELECT 'ESTADO|transaccion_solo_lectura|' || current_setting('transaction_read_only');
SELECT 'ESTADO|staging_marca|' || (to_regnamespace('staging_marca') IS NOT NULL);
SELECT 'PERFIL|activos|' || (SELECT count(*) FROM app.perfiles_usuario WHERE activo);
SELECT 'PERFIL|total|' || (SELECT count(*) FROM app.perfiles_usuario);
SELECT 'PERFIL|user_id|' || p.user_id || '|licencia=' || p.id_licencia || '|id_cliente=' || COALESCE(p.id_cliente, '(nulo)') || '|rol=' || p.rol || '|activo=' || p.activo
  FROM app.perfiles_usuario p ORDER BY p.creado_at;
SELECT 'AUTH|usuarios|' || (SELECT count(*) FROM auth.users);
SELECT 'AUTH|usuario_del_perfil|' || u.id || '|correo_termina_en_invalid=' || (lower(u.email) LIKE '%.invalid')
  FROM auth.users u WHERE u.id IN (SELECT user_id FROM app.perfiles_usuario WHERE activo) ORDER BY u.id;
SELECT 'RESULTADO|OK';
ROLLBACK;
