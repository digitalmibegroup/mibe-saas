-- ============================================================================
-- HITO 6.18.9 — RPC transaccional para eliminación atómica de compras
-- ============================================================================
-- NO EJECUTADO AUTOMÁTICAMENTE. Este archivo es un ENTREGABLE para que el
-- propietario del proyecto lo revise y, si lo autoriza explícitamente, lo
-- aplique manualmente en el SQL Editor de Supabase (Project > SQL Editor).
--
-- Este entorno de trabajo (Claude Code) no tiene acceso al SQL Editor de
-- Supabase, a la Supabase CLI, ni a una conexión directa a Postgres con
-- permisos DDL — solo a la API REST (PostgREST) con la anon key. Por eso esta
-- función no pudo desplegarse como parte del HITO 6.18.9; solo puede
-- diseñarse y entregarse aquí.
--
-- QUÉ RESUELVE que la mitigación de frontend (HITO 6.18.9, estado transicional
-- 'eliminando') NO resuelve: si una compra tiene varios productos y el
-- producto 2 falla después de que el producto 1 ya fue revertido, esta
-- función SÍ deshace automáticamente la reversión del producto 1 (rollback
-- real de transacción). La mitigación de frontend deja esa compra en
-- 'eliminando', visible y no reprocesable, pero no deshace nada por sí sola.
--
-- DISEÑO:
--  - Recalcula TODO desde la base de datos: nunca confía en cantidades
--    enviadas por el frontend. Relee compras_items, inventario /
--    inventario_bodega directamente.
--  - unidades físicas = qty × uds_empaque(de la compra), igual que
--    unidadesFisicasDeCompra() en el frontend (HITO 6.18.6). NOTA: la tabla
--    compras_items no tiene columna "sueltas" (confirmado por lectura del
--    esquema real) — la misma limitación que ya tiene el código JS actual al
--    releer una compra guardada, no es una regresión de esta función.
--  - El pool existente y el resultado SIEMPRE se expresan en uds_empaque del
--    PRODUCTO MAESTRO (leído fresco dentro de la misma transacción con
--    SELECT ... FOR UPDATE), nunca en la presentación de la compra — mismo
--    principio de HITO 6.18.6/6.18.7/6.18.8.
--  - SELECT ... FOR UPDATE sobre la compra y sobre cada fila de inventario
--    tocada: bloqueo real de Postgres. Una segunda llamada concurrente sobre
--    la MISMA compra o el MISMO producto espera hasta que la primera
--    transacción termine (commit o rollback), luego relee el valor ya
--    actualizado — cierra doble clic, dos pestañas y condiciones de carrera
--    de forma real, no simulada.
--  - CUALQUIER fallo usa RAISE EXCEPTION, nunca un simple RETURN con un
--    jsonb de error. Esto es intencional y crítico: en PL/pgSQL, un RETURN
--    normal NO deshace los UPDATE ya ejecutados en la misma invocación si la
--    transacción que la envuelve hace COMMIT — solo una excepción sin
--    capturar fuerza el ROLLBACK automático de TODA la función. Sin esto, la
--    función parecería "transaccional" pero no lo sería.
--  - Multi-tenant: valida id_licencia en cada tabla tocada (compras,
--    inventario, inventario_bodega, bodegas). Un tenant no puede eliminar ni
--    leer compras de otro tenant a través de esta función.
--
-- LIMITACIÓN DE SEGURIDAD HEREDADA (no introducida ni resuelta por esta
-- función): este proyecto no usa Supabase Auth — el frontend llama a la API
-- con la anon key pública y decide el tenant enviando id_licencia como
-- parámetro de query/body. Cualquier poseedor de la anon key puede, hoy,
-- pasar el id_licencia que quiera para leer o escribir datos de cualquier
-- tenant — esto es así en TODA la aplicación actual, no solo en esta función,
-- y no se resuelve aquí porque está fuera del alcance de HITO 6.18.9. Esta
-- función no amplía esa exposición (aplica exactamente los mismos filtros
-- por id_licencia que ya usa el resto de la app), pero tampoco la cierra.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_eliminar_compra_atomica(
  p_compra_id uuid,
  p_id_licencia text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_compra          record;
  v_item            record;
  v_id_bodega       uuid;
  v_uds_emp         numeric;
  v_stock_act       numeric;
  v_sueltas_act     numeric;
  v_pool_actual     numeric;
  v_pool_nuevo      numeric;
BEGIN
  -- 1) Bloquear la fila de la compra dentro de esta transacción. Una segunda
  --    llamada concurrente sobre la MISMA compra espera aquí.
  SELECT * INTO v_compra
    FROM compras
    WHERE id = p_compra_id AND id_licencia = p_id_licencia
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La compra no existe o no pertenece a este tenant.'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_compra.estado <> 'recibida' THEN
    RAISE EXCEPTION 'Esta compra está en estado "%", no en "recibida" — no se puede eliminar con reversión de inventario.', v_compra.estado
      USING ERRCODE = 'P0001';
  END IF;

  IF v_compra.destino = 'bodega_secundaria' THEN
    SELECT id INTO v_id_bodega FROM bodegas WHERE id_licencia = p_id_licencia LIMIT 1;
    IF v_id_bodega IS NULL THEN
      RAISE EXCEPTION 'No existe una bodega secundaria configurada para este tenant.'
        USING ERRCODE = 'P0003';
    END IF;
  END IF;

  -- 2) Recorrer, agrupadas por producto, las unidades físicas REALES de la
  --    compra — recalculadas desde compras_items, nunca desde el frontend.
  FOR v_item IN
    SELECT ci.prod_id AS prod_id,
           SUM(ci.qty * COALESCE(ci.uds_empaque, 1)) AS unidades_fisicas,
           MIN(ci.nombre) AS nombre
    FROM compras_items ci
    WHERE ci.compra_id = p_compra_id
    GROUP BY ci.prod_id
  LOOP
    IF v_compra.destino = 'bodega_secundaria' THEN
      -- inventario_bodega no tiene columna uds_empaque propia: se lee del
      -- producto maestro, bloqueando también esa fila (misma transacción).
      SELECT uds_empaque INTO v_uds_emp
        FROM inventario
        WHERE id = v_item.prod_id AND id_licencia = p_id_licencia
        FOR UPDATE;
      v_uds_emp := COALESCE(v_uds_emp, 1);

      SELECT stock, uds_sueltas INTO v_stock_act, v_sueltas_act
        FROM inventario_bodega
        WHERE id_licencia = p_id_licencia AND id_bodega = v_id_bodega AND prod_id = v_item.prod_id
        FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto "%" ya no existe en el inventario de la bodega.', v_item.nombre
          USING ERRCODE = 'P0004';
      END IF;

      v_pool_actual := v_stock_act * v_uds_emp + v_sueltas_act;
      IF v_pool_actual < v_item.unidades_fisicas THEN
        RAISE EXCEPTION 'No hay suficiente inventario físico en bodega para revertir "%": disponible %, requerido %.',
          v_item.nombre, v_pool_actual, v_item.unidades_fisicas
          USING ERRCODE = 'P0005';
      END IF;
      v_pool_nuevo := v_pool_actual - v_item.unidades_fisicas;

      UPDATE inventario_bodega
        SET stock = floor(v_pool_nuevo / v_uds_emp),
            uds_sueltas = v_pool_nuevo - floor(v_pool_nuevo / v_uds_emp) * v_uds_emp,
            updated_at = now()
        WHERE id_licencia = p_id_licencia AND id_bodega = v_id_bodega AND prod_id = v_item.prod_id;

    ELSE
      -- inventario principal: se lee y bloquea stock/uds_sueltas/uds_empaque
      -- del producto en una sola fila.
      SELECT uds_empaque, stock, uds_sueltas INTO v_uds_emp, v_stock_act, v_sueltas_act
        FROM inventario
        WHERE id = v_item.prod_id AND id_licencia = p_id_licencia
        FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto "%" ya no existe en el inventario principal.', v_item.nombre
          USING ERRCODE = 'P0004';
      END IF;
      v_uds_emp := COALESCE(v_uds_emp, 1);

      v_pool_actual := v_stock_act * v_uds_emp + v_sueltas_act;
      IF v_pool_actual < v_item.unidades_fisicas THEN
        RAISE EXCEPTION 'No hay suficiente inventario físico para revertir "%": disponible %, requerido %.',
          v_item.nombre, v_pool_actual, v_item.unidades_fisicas
          USING ERRCODE = 'P0005';
      END IF;
      v_pool_nuevo := v_pool_actual - v_item.unidades_fisicas;

      UPDATE inventario
        SET stock = floor(v_pool_nuevo / v_uds_emp),
            uds_sueltas = v_pool_nuevo - floor(v_pool_nuevo / v_uds_emp) * v_uds_emp
        WHERE id = v_item.prod_id AND id_licencia = p_id_licencia;
    END IF;
  END LOOP;

  -- 3) Solo si TODOS los productos se revirtieron sin excepción, borrar los
  --    registros de la compra.
  DELETE FROM compras_items WHERE compra_id = p_compra_id;
  DELETE FROM compras WHERE id = p_compra_id AND id_licencia = p_id_licencia;

  RETURN jsonb_build_object('ok', true, 'compra_id', p_compra_id);
END;
$$;

-- Permite invocar la funcion desde el frontend con la anon key, igual que
-- fn_trasladar_inventario ya existente. NO expone service_role al navegador:
-- el navegador nunca ve credenciales nuevas, solo llama a POST /rest/v1/rpc/...
-- con la misma anon key que ya usa hoy para todo lo demas.
GRANT EXECUTE ON FUNCTION fn_eliminar_compra_atomica(uuid, text) TO anon, authenticated;

-- ============================================================================
-- Invocación desde el frontend (ejemplo, NO implementado todavía):
--
--   var r = await fetch(SB+'/rest/v1/rpc/fn_eliminar_compra_atomica', {
--     method: 'POST', headers: H,
--     body: JSON.stringify({ p_compra_id: id, p_id_licencia: CID })
--   });
--   if (!r.ok) { var err = await r.json(); toast(err.message); return; }
--
-- Conectar eliminarCompra() a esta RPC es un cambio de frontend que debe
-- hacerse en un hito posterior, DESPUÉS de que esta función se aplique y se
-- pruebe manualmente en Supabase — no antes.
-- ============================================================================
