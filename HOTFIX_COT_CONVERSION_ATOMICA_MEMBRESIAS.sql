-- HOTFIX COTIZACIONES — membresias del rol cotconv_ejecutor (SOLO LECTURA, un unico SELECT).
-- El instalador concede una membresia temporal (SET) para poder fijar los permisos de EXECUTE y la retira antes del COMMIT.
-- Esta consulta comprueba que no queda ninguna membresia con SET ni INHERIT. Una fila con solo admin=true (opcion de administrador que
-- PostgreSQL da al creador del rol) es normal. Esperado: RESULTADO_MEMBRESIAS|con_set_o_inherit=0
SELECT linea FROM (
  SELECT 1 AS o, 'MEMBRESIA|miembro=' || m.member::regrole::text || '|otorgante=' || m.grantor::regrole::text
         || '|set=' || m.set_option || '|inherit=' || m.inherit_option || '|admin=' || m.admin_option AS linea
    FROM pg_auth_members m WHERE m.roleid = 'cotconv_ejecutor'::regrole
  UNION ALL
  SELECT 2, 'RESULTADO_MEMBRESIAS|con_set_o_inherit=' || count(*)
    FROM pg_auth_members m WHERE m.roleid = 'cotconv_ejecutor'::regrole AND (m.set_option OR m.inherit_option)
) t ORDER BY o, linea;
