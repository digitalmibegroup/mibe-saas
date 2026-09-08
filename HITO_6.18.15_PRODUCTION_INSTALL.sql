-- ============================================================================
-- HITO 6.18.15 (Fase 8.5) — ARTEFACTO DE INSTALACION PARA PRODUCCION
-- ============================================================================
-- NO EJECUTAR ESTE ARCHIVO TODAVIA. Es un ENTREGABLE preparado para que el
-- propietario del proyecto lo revise y, SOLO tras autorizacion explicita, lo
-- ejecute manualmente en el SQL Editor del proyecto Supabase de PRODUCCION.
--
-- Este archivo NUNCA fue ejecutado desde este entorno. Fue ensamblado de
-- forma programatica (no transcrito a mano) a partir del contenido EXACTO,
-- ya corregido (SQLSTATE LC010-LC013, REVOKE PUBLIC) y validado
-- funcionalmente en el Sandbox local (PostgreSQL 17.11, 10/10 tests,
-- concurrencia real, aislamiento multi-tenant), de los 3 archivos:
--   HITO_6.18.15_RPC_RECIBIR_COMPRA.sql
--   HITO_6.18.15_RPC_EDITAR_COMPRA.sql
--   HITO_6.18.15_RPC_ELIMINAR_COMPRA.sql
--
-- REGLA ABSOLUTA: si cualquiera de los guards de abajo detecta una
-- precondicion no cumplida (tabla/columna faltante, o una funcion YA
-- EXISTENTE con la misma firma), el script se detiene con un RAISE
-- EXCEPTION antes de crear nada mas. NO se usa CREATE OR REPLACE a ciegas
-- sobre una funcion desconocida.
--
-- Este archivo NO modifica datos, NO modifica el frontend, NO modifica
-- RLS, NO modifica policies, NO modifica grants de tabla, NO modifica FK,
-- NO modifica HITO_6.18.9_rpc_eliminar_compra.sql.
-- ============================================================================

-- ============================================================================
-- PASO 0 — VERIFICACION DE PRECONDICIONES (tablas y columnas requeridas)
-- ============================================================================
DO $verify$
DECLARE
  v_missing text := '';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='compras') THEN
    v_missing := v_missing || 'compras ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='compras_items') THEN
    v_missing := v_missing || 'compras_items ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='inventario') THEN
    v_missing := v_missing || 'inventario ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='inventario_bodega') THEN
    v_missing := v_missing || 'inventario_bodega ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='bodegas') THEN
    v_missing := v_missing || 'bodegas ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='proveedores') THEN
    v_missing := v_missing || 'proveedores ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='compras' AND column_name='id_licencia') THEN
    v_missing := v_missing || 'compras.id_licencia ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='compras_items' AND column_name='compra_id') THEN
    v_missing := v_missing || 'compras_items.compra_id ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='inventario' AND column_name='uds_empaque') THEN
    v_missing := v_missing || 'inventario.uds_empaque ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='inventario_bodega' AND column_name='id_bodega') THEN
    v_missing := v_missing || 'inventario_bodega.id_bodega ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pgcrypto') THEN
    v_missing := v_missing || 'extension:pgcrypto ';
  END IF;
  IF v_missing <> '' THEN
    RAISE EXCEPTION 'PRECONDICION NO CUMPLIDA -- faltan: %. Instalacion detenida, no se creo ninguna funcion.', v_missing;
  END IF;
  RAISE NOTICE 'Precondiciones OK -- todas las tablas/columnas/extension requeridas existen.';
END
$verify$;

-- ============================================================================
-- PASO 1 — GUARD: recibir_compra_atomica NO debe existir ya
-- ============================================================================
DO $guard1$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='recibir_compra_atomica'
  ) THEN
    RAISE EXCEPTION 'GUARD: recibir_compra_atomica YA EXISTE en este esquema. Instalacion detenida -- revisar manualmente antes de continuar (no se usa CREATE OR REPLACE a ciegas). Consultar su definicion con pg_get_functiondef antes de decidir.';
  END IF;
END
$guard1$;

-- ---- Definicion exacta de recibir_compra_atomica (extraida sin cambios de
--      HITO_6.18.15_RPC_RECIBIR_COMPRA.sql, ya validada en Sandbox) ----
CREATE OR REPLACE FUNCTION recibir_compra_atomica(
  p_compra_id    uuid,
  p_id_licencia  text
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_compra        record;
  v_id_bodega     uuid;
  v_item          record;
  v_uds_emp       numeric;
  v_stock_act     numeric;
  v_sueltas_act   numeric;
  v_pool_actual   numeric;
  v_pool_nuevo    numeric;
  v_num_items     integer;
BEGIN
  -- lock_timeout defensivo: si otra transacción tiene la fila bloqueada por
  -- más de 10s, esta llamada falla con un error identificable en vez de
  -- colgarse indefinidamente. Es un valor conservador, ajustable.
  SET LOCAL lock_timeout = '10s';

  -- 1) Bloquear la compra. Una segunda llamada concurrente sobre la MISMA
  --    compra espera aquí hasta que esta transacción termine.
  SELECT * INTO v_compra
    FROM compras
    WHERE id = p_compra_id AND id_licencia = p_id_licencia
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La compra no existe o no pertenece a este tenant.'
      USING ERRCODE = 'LC011';
  END IF;

  -- 2) Estado: solo 'pendiente' puede recibirse. Distinguir el caso "ya
  --    procesada con éxito" del resto de estados inválidos, para que el
  --    frontend pueda mostrar un mensaje más preciso si lo desea.
  IF v_compra.estado = 'recibida' THEN
    RAISE EXCEPTION 'Esta compra ya fue marcada como recibida anteriormente.'
      USING ERRCODE = 'P0006';
  ELSIF v_compra.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'Esta compra está en estado "%", no en "pendiente" — no se puede recibir.', v_compra.estado
      USING ERRCODE = 'LC010';
  END IF;

  -- 3) Destino.
  IF v_compra.destino = 'bodega_secundaria' THEN
    SELECT id INTO v_id_bodega FROM bodegas WHERE id_licencia = p_id_licencia LIMIT 1;
    IF v_id_bodega IS NULL THEN
      RAISE EXCEPTION 'No existe una bodega secundaria configurada para este tenant.'
        USING ERRCODE = 'LC012';
    END IF;
  ELSIF v_compra.destino <> 'principal' THEN
    RAISE EXCEPTION 'Esta compra no tiene un destino de inventario válido ("%").', v_compra.destino
      USING ERRCODE = 'LC002';
  END IF;

  -- 4) Debe tener items.
  SELECT count(*) INTO v_num_items FROM compras_items WHERE compra_id = p_compra_id;
  IF v_num_items = 0 THEN
    RAISE EXCEPTION 'Esta compra no tiene productos registrados.'
      USING ERRCODE = 'LC001';
  END IF;

  -- 5) Recorrer, agrupadas por producto y en orden determinístico (evita
  --    deadlocks contra otras RPC que también bloqueen productos), las
  --    unidades físicas REALES de la compra.
  --    unidades_fisicas = qty × uds_empaque(de la compra) + COALESCE(sueltas,0).
  --    NOTA — LIMITACIÓN YA DOCUMENTADA (no corregida aquí, fuera de alcance
  --    de 6.18.15): compras_items NO tiene columna "sueltas" en el esquema
  --    real (confirmado en Fase 1 y re-confirmado en Fase 2). Por tanto el
  --    término "+ sueltas" es conceptualmente correcto pero hoy SIEMPRE
  --    aporta 0 — exactamente la misma limitación que ya tiene el código JS
  --    actual al releer una compra guardada. Si en el futuro se agrega esa
  --    columna, esta consulta debe actualizarse a SUM(ci.qty * COALESCE(ci.uds_empaque,1) + COALESCE(ci.sueltas,0)).
  -- NOTA sobre costo_ultimo: si un mismo prod_id aparece en más de una línea
  -- de la misma compra (poco frecuente — el frontend actual fusiona líneas
  -- del mismo producto al agregar, pero una compra_items histórica podría
  -- tener varias filas separadas), NO se debe sumar el costo (SUM() sería
  -- incorrecto: sumaría precios en vez de elegir uno). Se usa MAX(...) FILTER
  -- como criterio determinístico y explícito para elegir un único costo
  -- representativo entre los positivos — decisión documentada, no un olvido.
  FOR v_item IN
    SELECT ci.prod_id AS prod_id,
           SUM(ci.qty * COALESCE(ci.uds_empaque, 1)) AS unidades_fisicas,
           MAX(ci.costo) FILTER (WHERE ci.costo > 0) AS costo_ultimo,
           MIN(ci.nombre) AS nombre,
           MIN(ci.tipo) AS tipo,
           MIN(ci.uds_empaque) AS uds_empaque_compra
    FROM compras_items ci
    WHERE ci.compra_id = p_compra_id
    GROUP BY ci.prod_id
    ORDER BY ci.prod_id
  LOOP
    IF v_item.unidades_fisicas IS NULL OR v_item.unidades_fisicas <= 0 THEN
      RAISE EXCEPTION 'La cantidad de "%" en esta compra no es válida.', v_item.nombre
        USING ERRCODE = 'LC005';
    END IF;

    IF v_compra.destino = 'bodega_secundaria' THEN
      -- inventario_bodega no tiene uds_empaque propia: se lee del producto
      -- maestro, bloqueando también esa fila en la MISMA transacción.
      SELECT uds_empaque INTO v_uds_emp
        FROM inventario
        WHERE id = v_item.prod_id AND id_licencia = p_id_licencia
        FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto "%" no existe en el inventario principal de este tenant.', v_item.nombre
          USING ERRCODE = 'LC013';
      END IF;
      v_uds_emp := COALESCE(v_uds_emp, 1);
      IF v_uds_emp <= 0 THEN
        RAISE EXCEPTION 'El producto "%" tiene una configuración de presentación inválida (uds_empaque <= 0).', v_item.nombre
          USING ERRCODE = 'LC003';
      END IF;

      -- Crear la fila en inventario_bodega si no existe, DENTRO de la misma
      -- transacción (evita la ventana GET→POST→PATCH separada que tiene hoy
      -- aplicarCompraAInventarioBodega() en el frontend). ON CONFLICT
      -- protege contra una inserción concurrente de otra transacción que
      -- estuviera esperando el mismo lock_timeout más abajo.
      INSERT INTO inventario_bodega (id_licencia, id_bodega, prod_id, stock, uds_sueltas)
        VALUES (p_id_licencia, v_id_bodega, v_item.prod_id, 0, 0)
        ON CONFLICT DO NOTHING;

      SELECT stock, uds_sueltas INTO v_stock_act, v_sueltas_act
        FROM inventario_bodega
        WHERE id_licencia = p_id_licencia AND id_bodega = v_id_bodega AND prod_id = v_item.prod_id
        FOR UPDATE;

      v_pool_actual := COALESCE(v_stock_act, 0) * v_uds_emp + COALESCE(v_sueltas_act, 0);
      v_pool_nuevo  := v_pool_actual + v_item.unidades_fisicas;

      UPDATE inventario_bodega
        SET stock = floor(v_pool_nuevo / v_uds_emp),
            uds_sueltas = v_pool_nuevo - floor(v_pool_nuevo / v_uds_emp) * v_uds_emp,
            precio_costo = CASE WHEN v_item.costo_ultimo > 0 THEN v_item.costo_ultimo ELSE precio_costo END,
            updated_at = now()
        WHERE id_licencia = p_id_licencia AND id_bodega = v_id_bodega AND prod_id = v_item.prod_id;

    ELSE
      -- Inventario principal: se lee y bloquea uds_empaque/stock/uds_sueltas
      -- del producto en una sola fila.
      SELECT uds_empaque, stock, uds_sueltas INTO v_uds_emp, v_stock_act, v_sueltas_act
        FROM inventario
        WHERE id = v_item.prod_id AND id_licencia = p_id_licencia
        FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto "%" no existe en el inventario principal de este tenant.', v_item.nombre
          USING ERRCODE = 'LC013';
      END IF;
      v_uds_emp := COALESCE(v_uds_emp, 1);
      IF v_uds_emp <= 0 THEN
        RAISE EXCEPTION 'El producto "%" tiene una configuración de presentación inválida (uds_empaque <= 0).', v_item.nombre
          USING ERRCODE = 'LC003';
      END IF;

      v_pool_actual := COALESCE(v_stock_act, 0) * v_uds_emp + COALESCE(v_sueltas_act, 0);
      v_pool_nuevo  := v_pool_actual + v_item.unidades_fisicas;

      UPDATE inventario
        SET stock = floor(v_pool_nuevo / v_uds_emp),
            uds_sueltas = v_pool_nuevo - floor(v_pool_nuevo / v_uds_emp) * v_uds_emp,
            precio_costo = CASE WHEN v_item.costo_ultimo > 0 THEN v_item.costo_ultimo ELSE precio_costo END
        WHERE id = v_item.prod_id AND id_licencia = p_id_licencia;
    END IF;

    -- producto_presentaciones (shadow-write) — DECISIÓN EXPLÍCITA: se deja
    -- FUERA de esta transacción. Ver justificación completa en el informe de
    -- Fase 2, sección "PRODUCTO_PRESENTACIONES". Resumen: es una caché
    -- derivada (no historial transaccional, ya establecido en HITO
    -- 6.18.14-E), y encadenar su éxito al de la recepción de inventario
    -- haría que un fallo de bajo impacto (p.ej. un choque de índice único en
    -- esa tabla) revierta una operación de alto impacto y ya validada
    -- (la entrada real de inventario). El frontend, tras recibir {ok:true}
    -- de esta función, sigue siendo responsable de llamar a
    -- shadowWritePresentacion() exactamente como hace hoy tras un PATCH
    -- directo exitoso — sin cambios de comportamiento visible.

  END LOOP;

  -- 6) Solo si TODOS los productos se aplicaron sin excepción, confirmar el
  --    estado de la compra.
  UPDATE compras SET estado = 'recibida' WHERE id = p_compra_id AND id_licencia = p_id_licencia;

  RETURN jsonb_build_object('ok', true, 'compra_id', p_compra_id, 'estado', 'recibida');

EXCEPTION
  WHEN lock_not_available THEN
    RAISE EXCEPTION 'No se pudo obtener acceso exclusivo a tiempo (otra operación sobre esta compra o producto está en curso) — inténtalo de nuevo.'
      USING ERRCODE = 'LC007';
END;
$$;

-- Permite invocar la función desde el frontend con la anon key, igual que
-- fn_eliminar_compra_atomica (6.18.9) y fn_trasladar_inventario ya existentes.
GRANT EXECUTE ON FUNCTION recibir_compra_atomica(uuid, text) TO anon, authenticated;

-- HITO 6.18.15 Fase 8.1: PostgreSQL otorga EXECUTE a PUBLIC por defecto al crear
-- cualquier función, sin que nadie lo pida explícitamente. Se revoca aquí por
-- mínimo privilegio — anon/authenticated ya tienen su propio GRANT explícito
-- arriba, así que esto no cambia quién puede invocar la función en la práctica
-- (el frontend actual solo usa anon), solo cierra una superficie innecesaria.
REVOKE EXECUTE ON FUNCTION recibir_compra_atomica(uuid, text) FROM PUBLIC;

-- Verificacion inmediata post-instalacion de RPC #1 (solo lectura)
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.prosecdef AS security_definer, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='recibir_compra_atomica';

SELECT grantee, privilege_type FROM information_schema.routine_privileges
WHERE routine_schema='public' AND routine_name='recibir_compra_atomica' ORDER BY grantee;

-- ============================================================================
-- PASO 2 — GUARD: editar_compra_atomica NO debe existir ya
-- ============================================================================
DO $guard2$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='editar_compra_atomica'
  ) THEN
    RAISE EXCEPTION 'GUARD: editar_compra_atomica YA EXISTE en este esquema. Instalacion detenida -- revisar manualmente antes de continuar.';
  END IF;
END
$guard2$;

-- ---- Definicion exacta de editar_compra_atomica (extraida sin cambios de
--      HITO_6.18.15_RPC_EDITAR_COMPRA.sql, ya validada en Sandbox) ----
CREATE OR REPLACE FUNCTION editar_compra_atomica(
  p_compra_id    uuid,
  p_id_licencia  text,
  p_modo         text,           -- expectativa del cliente: 'completa' | 'limitada'
  p_proveedor_id uuid,           -- puede ser NULL ("Sin proveedor")
  p_fecha        date,
  p_nota         text,
  p_destino      text DEFAULT NULL,   -- solo se usa si el modo real es 'completa'
  p_items        jsonb DEFAULT NULL  -- solo se usa si el modo real es 'completa'
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_compra          record;
  v_modo_real       text;
  v_item            jsonb;
  v_prod_id         text;
  v_qty             numeric;
  v_costo           numeric;
  v_uds_empaque     numeric;
  v_tipo            text;
  v_nombre_prod     text;
  v_nombre_final    text;
  v_proveedor_nombre text;
  v_total           numeric;
  v_num_items       integer;
BEGIN
  SET LOCAL lock_timeout = '10s';

  -- 1) Bloquear la compra.
  SELECT * INTO v_compra
    FROM compras
    WHERE id = p_compra_id AND id_licencia = p_id_licencia
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La compra no existe o no pertenece a este tenant.'
      USING ERRCODE = 'LC011';
  END IF;

  -- 2) Política de edición — la función es la autoridad, no el parámetro.
  v_modo_real := CASE v_compra.estado
    WHEN 'pendiente' THEN 'completa'
    WHEN 'recibida'  THEN 'limitada'
    ELSE NULL
  END;

  IF v_modo_real IS NULL THEN
    RAISE EXCEPTION 'Esta compra está en estado "%" y no puede modificarse (recibiendo/eliminando/editando/cancelada son estados bloqueados).', v_compra.estado
      USING ERRCODE = 'LC010';
  END IF;

  IF p_modo IS DISTINCT FROM v_modo_real THEN
    RAISE EXCEPTION 'El modo de edición esperado por el cliente ("%") ya no coincide con el estado real de la compra ("%", modo "%") — probablemente otro proceso la modificó mientras se editaba. Actualiza e inténtalo de nuevo.', p_modo, v_compra.estado, v_modo_real
      USING ERRCODE = 'LC010';
  END IF;

  -- 3) Resolver nombre de proveedor (puede ser NULL).
  IF p_proveedor_id IS NOT NULL THEN
    SELECT nombre INTO v_proveedor_nombre FROM proveedores WHERE id = p_proveedor_id AND id_licencia = p_id_licencia;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El proveedor indicado no existe o no pertenece a este tenant.'
        USING ERRCODE = 'LC004';
    END IF;
  ELSE
    v_proveedor_nombre := 'Sin proveedor';
  END IF;

  IF v_modo_real = 'completa' THEN
    -- ---- MODO COMPLETA (compra pendiente): proveedor, fecha, nota,
    --      destino, items — nunca toca inventario. ----

    IF p_destino NOT IN ('principal', 'bodega_secundaria') THEN
      RAISE EXCEPTION 'Debes seleccionar un destino de inventario válido antes de guardar.'
        USING ERRCODE = 'LC002';
    END IF;

    IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
      RAISE EXCEPTION 'Agrega al menos un producto antes de guardar.'
        USING ERRCODE = 'LC001';
    END IF;

    -- ---- PASADA 1: validar TODOS los items, sin escribir nada todavía. ----
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      v_prod_id     := v_item->>'prod_id';
      v_qty         := (v_item->>'qty')::numeric;
      v_costo       := (v_item->>'costo')::numeric;
      v_uds_empaque := COALESCE((v_item->>'uds_empaque')::numeric, 1);
      v_tipo        := COALESCE(v_item->>'tipo', 'unidad');

      IF v_prod_id IS NULL OR v_prod_id = '' THEN
        RAISE EXCEPTION 'Uno de los productos de la edición no tiene un identificador válido.'
          USING ERRCODE = 'LC013';
      END IF;

      -- Verificar que el producto exista y pertenezca al tenant (lectura,
      -- sin bloquear — la edición no modifica inventario, así que no hace
      -- falta FOR UPDATE aquí; solo se usa para validar existencia real).
      SELECT nombre INTO v_nombre_prod FROM inventario WHERE id = v_prod_id AND id_licencia = p_id_licencia;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto "%" no existe en el inventario de este tenant.', v_prod_id
          USING ERRCODE = 'LC013';
      END IF;

      IF v_qty IS NULL OR v_qty <= 0 THEN
        RAISE EXCEPTION 'La cantidad de "%" no es válida (debe ser mayor que 0).', v_nombre_prod
          USING ERRCODE = 'LC005';
      END IF;

      IF v_costo IS NULL OR v_costo < 0 THEN
        RAISE EXCEPTION 'El costo de "%" no es válido (no puede ser negativo).', v_nombre_prod
          USING ERRCODE = 'LC006';
      END IF;

      IF v_uds_empaque <= 0 THEN
        RAISE EXCEPTION 'La presentación de "%" no es válida (uds_empaque <= 0).', v_nombre_prod
          USING ERRCODE = 'LC003';
      END IF;

      IF v_tipo NOT IN ('unidad', 'sixpack', 'caja', 'empaque') THEN
        RAISE EXCEPTION 'El tipo de presentación de "%" no es reconocido ("%").', v_nombre_prod, v_tipo
          USING ERRCODE = 'LC003';
      END IF;
    END LOOP;
    -- Si se llegó aquí, TODOS los items del array son válidos. Recién ahora
    -- se escribe algo.

    -- ---- PASADA 2: reemplazar items y actualizar cabecera. ----
    DELETE FROM compras_items WHERE compra_id = p_compra_id;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
      v_prod_id     := v_item->>'prod_id';
      v_qty         := (v_item->>'qty')::numeric;
      v_costo       := (v_item->>'costo')::numeric;
      v_uds_empaque := COALESCE((v_item->>'uds_empaque')::numeric, 1);
      v_tipo        := COALESCE(v_item->>'tipo', 'unidad');
      v_nombre_final := COALESCE(v_item->>'nombre', v_prod_id);

      INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
        VALUES (p_compra_id, v_prod_id, v_nombre_final, v_qty, v_costo, v_qty * v_costo, v_tipo, v_uds_empaque);
    END LOOP;

    -- Total SIEMPRE derivado de los items ya persistidos — nunca de un
    -- parámetro de total enviado por el cliente (HITO 6.18.14-D, sección 29
    -- del diseño de Fase 1: "nunca confiar en un total introducido
    -- manualmente").
    SELECT COALESCE(SUM(subtotal), 0) INTO v_total FROM compras_items WHERE compra_id = p_compra_id;

    UPDATE compras SET
      proveedor_id   = p_proveedor_id,
      proveedor_nombre = v_proveedor_nombre,
      fecha          = p_fecha,
      nota           = p_nota,
      destino        = p_destino,
      total          = v_total,
      estado         = 'pendiente'
    WHERE id = p_compra_id AND id_licencia = p_id_licencia;

    RETURN jsonb_build_object('ok', true, 'compra_id', p_compra_id, 'modo', 'completa', 'total', v_total);

  ELSE
    -- ---- MODO LIMITADA (compra recibida): SOLO proveedor/fecha/nota.
    --      NUNCA lee ni escribe p_items/p_destino, NUNCA toca
    --      compras_items, inventario ni inventario_bodega, NUNCA cambia
    --      total. El estado permanece 'recibida'. ----

    UPDATE compras SET
      proveedor_id     = p_proveedor_id,
      proveedor_nombre = v_proveedor_nombre,
      fecha            = p_fecha,
      nota             = p_nota
      -- destino, total y estado NO se tocan intencionalmente.
    WHERE id = p_compra_id AND id_licencia = p_id_licencia;

    RETURN jsonb_build_object('ok', true, 'compra_id', p_compra_id, 'modo', 'limitada');
  END IF;

EXCEPTION
  WHEN lock_not_available THEN
    RAISE EXCEPTION 'No se pudo obtener acceso exclusivo a tiempo (otra operación sobre esta compra está en curso) — inténtalo de nuevo.'
      USING ERRCODE = 'LC007';
END;
$$;

GRANT EXECUTE ON FUNCTION editar_compra_atomica(uuid, text, text, uuid, date, text, text, jsonb) TO anon, authenticated;

-- HITO 6.18.15 Fase 8.1: revocar el EXECUTE que PostgreSQL otorga a PUBLIC por
-- defecto al crear cualquier función — mínimo privilegio, sin efecto práctico
-- (anon/authenticated ya tienen su GRANT explícito arriba).
REVOKE EXECUTE ON FUNCTION editar_compra_atomica(uuid, text, text, uuid, date, text, text, jsonb) FROM PUBLIC;

-- Verificacion inmediata post-instalacion de RPC #2 (solo lectura)
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.prosecdef AS security_definer, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='editar_compra_atomica';

SELECT grantee, privilege_type FROM information_schema.routine_privileges
WHERE routine_schema='public' AND routine_name='editar_compra_atomica' ORDER BY grantee;

-- ============================================================================
-- PASO 3 — GUARD: eliminar_compra_atomica NO debe existir ya
-- ============================================================================
DO $guard3$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='eliminar_compra_atomica'
  ) THEN
    RAISE EXCEPTION 'GUARD: eliminar_compra_atomica YA EXISTE en este esquema. Instalacion detenida. NOTA: fn_eliminar_compra_atomica (prefijo fn_, de HITO 6.18.9) es una funcion DISTINTA, no debe confundirse con esta.';
  END IF;
END
$guard3$;

-- ---- Definicion exacta de eliminar_compra_atomica (extraida sin cambios de
--      HITO_6.18.15_RPC_ELIMINAR_COMPRA.sql, ya validada en Sandbox) ----
CREATE OR REPLACE FUNCTION eliminar_compra_atomica(
  p_compra_id    uuid,
  p_id_licencia  text
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_compra          record;
  v_id_bodega       uuid;
  v_item            record;
  v_uds_emp         numeric;
  v_stock_act       numeric;
  v_sueltas_act     numeric;
  v_pool_actual     numeric;
  v_pool_nuevo      numeric;
BEGIN
  SET LOCAL lock_timeout = '10s';

  -- 1) Bloquear la compra.
  SELECT * INTO v_compra
    FROM compras
    WHERE id = p_compra_id AND id_licencia = p_id_licencia
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La compra no existe o no pertenece a este tenant.'
      USING ERRCODE = 'LC011';
  END IF;

  IF v_compra.estado <> 'recibida' THEN
    RAISE EXCEPTION 'Esta compra está en estado "%", no en "recibida" — no se puede eliminar con reversión de inventario.', v_compra.estado
      USING ERRCODE = 'LC010';
  END IF;

  IF v_compra.destino = 'bodega_secundaria' THEN
    SELECT id INTO v_id_bodega FROM bodegas WHERE id_licencia = p_id_licencia LIMIT 1;
    IF v_id_bodega IS NULL THEN
      RAISE EXCEPTION 'No existe una bodega secundaria configurada para este tenant.'
        USING ERRCODE = 'LC012';
    END IF;
  END IF;

  -- ---- PASADA 1: bloquear cada producto (FOR UPDATE) y VALIDAR que hay
  --      pool suficiente para revertir — SIN modificar nada todavía. Orden
  --      determinístico (ORDER BY prod_id) para prevenir deadlocks contra
  --      otras RPC de este batch que también bloqueen productos. ----
  FOR v_item IN
    SELECT ci.prod_id AS prod_id,
           SUM(ci.qty * COALESCE(ci.uds_empaque, 1)) AS unidades_fisicas,
           MIN(ci.nombre) AS nombre
    FROM compras_items ci
    WHERE ci.compra_id = p_compra_id
    GROUP BY ci.prod_id
    ORDER BY ci.prod_id
  LOOP
    IF v_compra.destino = 'bodega_secundaria' THEN
      SELECT uds_empaque INTO v_uds_emp
        FROM inventario
        WHERE id = v_item.prod_id AND id_licencia = p_id_licencia
        FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto "%" ya no existe en el inventario principal.', v_item.nombre
          USING ERRCODE = 'LC013';
      END IF;
      v_uds_emp := COALESCE(v_uds_emp, 1);

      SELECT stock, uds_sueltas INTO v_stock_act, v_sueltas_act
        FROM inventario_bodega
        WHERE id_licencia = p_id_licencia AND id_bodega = v_id_bodega AND prod_id = v_item.prod_id
        FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto "%" ya no existe en el inventario de la bodega.', v_item.nombre
          USING ERRCODE = 'LC013';
      END IF;

      v_pool_actual := v_stock_act * v_uds_emp + v_sueltas_act;
      IF v_pool_actual < v_item.unidades_fisicas THEN
        RAISE EXCEPTION 'No hay suficiente inventario físico en bodega para revertir "%": disponible %, requerido %.',
          v_item.nombre, v_pool_actual, v_item.unidades_fisicas
          USING ERRCODE = 'P0005';
      END IF;

    ELSE
      SELECT uds_empaque, stock, uds_sueltas INTO v_uds_emp, v_stock_act, v_sueltas_act
        FROM inventario
        WHERE id = v_item.prod_id AND id_licencia = p_id_licencia
        FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto "%" ya no existe en el inventario principal.', v_item.nombre
          USING ERRCODE = 'LC013';
      END IF;
      v_uds_emp := COALESCE(v_uds_emp, 1);

      v_pool_actual := v_stock_act * v_uds_emp + v_sueltas_act;
      IF v_pool_actual < v_item.unidades_fisicas THEN
        RAISE EXCEPTION 'No hay suficiente inventario físico para revertir "%": disponible %, requerido %.',
          v_item.nombre, v_pool_actual, v_item.unidades_fisicas
          USING ERRCODE = 'P0005';
      END IF;
    END IF;
    -- Nada se ha escrito todavía en esta pasada — solo se bloquearon filas
    -- (el lock se mantiene hasta el commit/rollback final de la función) y
    -- se validó suficiencia. Si CUALQUIER producto de la compra falla esta
    -- validación, la excepción aborta antes de que ningún UPDATE exista.
  END LOOP;

  -- ---- PASADA 2: todos los productos ya se validaron como revertibles.
  --      Ahora sí se aplican las reversiones, mismo orden determinístico. ----
  FOR v_item IN
    SELECT ci.prod_id AS prod_id,
           SUM(ci.qty * COALESCE(ci.uds_empaque, 1)) AS unidades_fisicas,
           MIN(ci.nombre) AS nombre
    FROM compras_items ci
    WHERE ci.compra_id = p_compra_id
    GROUP BY ci.prod_id
    ORDER BY ci.prod_id
  LOOP
    IF v_compra.destino = 'bodega_secundaria' THEN
      SELECT uds_empaque INTO v_uds_emp
        FROM inventario WHERE id = v_item.prod_id AND id_licencia = p_id_licencia;
      v_uds_emp := COALESCE(v_uds_emp, 1);

      SELECT stock, uds_sueltas INTO v_stock_act, v_sueltas_act
        FROM inventario_bodega
        WHERE id_licencia = p_id_licencia AND id_bodega = v_id_bodega AND prod_id = v_item.prod_id;

      v_pool_actual := v_stock_act * v_uds_emp + v_sueltas_act;
      v_pool_nuevo  := v_pool_actual - v_item.unidades_fisicas;

      UPDATE inventario_bodega
        SET stock = floor(v_pool_nuevo / v_uds_emp),
            uds_sueltas = v_pool_nuevo - floor(v_pool_nuevo / v_uds_emp) * v_uds_emp,
            updated_at = now()
        WHERE id_licencia = p_id_licencia AND id_bodega = v_id_bodega AND prod_id = v_item.prod_id;
    ELSE
      SELECT uds_empaque, stock, uds_sueltas INTO v_uds_emp, v_stock_act, v_sueltas_act
        FROM inventario WHERE id = v_item.prod_id AND id_licencia = p_id_licencia;
      v_uds_emp := COALESCE(v_uds_emp, 1);

      v_pool_actual := v_stock_act * v_uds_emp + v_sueltas_act;
      v_pool_nuevo  := v_pool_actual - v_item.unidades_fisicas;

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

EXCEPTION
  WHEN lock_not_available THEN
    RAISE EXCEPTION 'No se pudo obtener acceso exclusivo a tiempo (otra operación sobre esta compra o producto está en curso) — inténtalo de nuevo.'
      USING ERRCODE = 'LC007';
END;
$$;

-- SECURITY: esta función se declara SIN "SECURITY DEFINER" (a diferencia de
-- fn_eliminar_compra_atomica en 6.18.9), por la misma razón de mínimo
-- privilegio documentada en HITO_6.18.15_RPC_RECIBIR_COMPRA.sql — el rol
-- anon ya ejecuta hoy, directamente vía REST, exactamente estas operaciones
-- (DELETE sobre compras/compras_items, UPDATE sobre inventario/
-- inventario_bodega) sin error de permisos, así que no hace falta elevar
-- privilegios para que esta función funcione.
GRANT EXECUTE ON FUNCTION eliminar_compra_atomica(uuid, text) TO anon, authenticated;

-- HITO 6.18.15 Fase 8.1: revocar el EXECUTE que PostgreSQL otorga a PUBLIC por
-- defecto al crear cualquier función — mínimo privilegio, sin efecto práctico
-- (anon/authenticated ya tienen su GRANT explícito arriba).
REVOKE EXECUTE ON FUNCTION eliminar_compra_atomica(uuid, text) FROM PUBLIC;

-- Verificacion inmediata post-instalacion de RPC #3 (solo lectura)
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.prosecdef AS security_definer, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='eliminar_compra_atomica';

SELECT grantee, privilege_type FROM information_schema.routine_privileges
WHERE routine_schema='public' AND routine_name='eliminar_compra_atomica' ORDER BY grantee;

-- ============================================================================
-- PASO 4 — VERIFICACION FINAL CONJUNTA (solo lectura, ejecutar tras las 3)
-- ============================================================================
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS returns,
       p.prosecdef AS security_definer, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN ('recibir_compra_atomica','editar_compra_atomica','eliminar_compra_atomica')
ORDER BY p.proname;

-- Confirmar PUBLIC ausente y anon/authenticated presentes en las 3
SELECT routine_name, grantee, privilege_type FROM information_schema.routine_privileges
WHERE routine_schema='public' AND routine_name IN ('recibir_compra_atomica','editar_compra_atomica','eliminar_compra_atomica')
ORDER BY routine_name, grantee;

-- Confirmar que tablas/PK/FK no cambiaron (comparar contra el snapshot de
-- Fase 8.2/8.5 antes y despues de este archivo)
SELECT (SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE') AS tablas,
       (SELECT count(*) FROM information_schema.table_constraints WHERE table_schema='public' AND constraint_type='PRIMARY KEY') AS pk,
       (SELECT count(*) FROM information_schema.table_constraints WHERE table_schema='public' AND constraint_type='FOREIGN KEY') AS fk;

-- ============================================================================
-- FIN DEL ARTEFACTO. Este archivo NO instala fixtures, NO ejecuta las RPC, NO
-- modifica el frontend. El smoke test (HITO_6.18.15_PRODUCTION_SMOKE_TEST.sql)
-- es un paso POSTERIOR y SEPARADO, a ejecutar solo tras confirmar que los 3
-- pasos de este archivo terminaron sin errores.
-- ============================================================================
