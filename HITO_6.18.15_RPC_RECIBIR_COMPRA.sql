-- ============================================================================
-- HITO 6.18.15 (Fase 2) — RPC transaccional para recepción atómica de compras
-- ============================================================================
-- NO EJECUTADO. Este archivo es un ENTREGABLE para que el propietario del
-- proyecto lo revise y, si lo autoriza explícitamente, lo aplique manualmente
-- en el SQL Editor de Supabase (Project > SQL Editor).
--
-- Este entorno de trabajo (Claude Code) NO tiene acceso a psql, a la Supabase
-- CLI, ni a una conexión directa a Postgres con permisos DDL/RPC — solo a la
-- API REST (PostgREST) con la anon key pública, que devuelve 401 al intentar
-- consultar el endpoint raíz (/rest/v1/) porque ese endpoint exige
-- service_role. Por eso esta función no pudo desplegarse ni probarse contra
-- una base real; solo puede diseñarse, redactarse y auditarse aquí.
--
-- TIPOS REALES DEL ESQUEMA (confirmados por lectura GET de datos reales
-- durante la auditoría de Fase 1 y re-verificados en Fase 2, NUNCA asumidos):
--   compras.id             uuid   (ej. "0b95d50a-91f8-4d8a-b843-f1e3671dac0d")
--   compras.id_licencia    text   (ej. "lacava")
--   compras.proveedor_id   uuid
--   compras.fecha          date   (ej. "2026-08-31", sin componente de hora)
--   compras.destino        text   ('principal' | 'bodega_secundaria')
--   compras.estado         text
--   compras_items.id         uuid
--   compras_items.compra_id  uuid  (FK conceptual a compras.id)
--   compras_items.prod_id    text  (⚠ NO es uuid — formato real: "prod_1778706953966",
--                                    coincide con inventario.id)
--   inventario.id           text  (mismo formato "prod_...", NO uuid)
--   inventario.id_licencia  text
--   inventario.stock, uds_sueltas, uds_empaque   numeric/integer (valores enteros observados)
--   inventario.precio_costo numeric
--   bodegas.id              uuid
--   bodegas.id_licencia     text
--   inventario_bodega.id_bodega  uuid (FK conceptual a bodegas.id)
--   inventario_bodega.prod_id    text (mismo formato que inventario.id)
--
-- CORRECCIÓN RESPECTO AL DISEÑO CONCEPTUAL DE FASE 1: aquella fase usó
-- "p_compra_id uuid" (correcto) pero no fue explícita sobre el tipo de
-- prod_id dentro del jsonb de items. Verificado ahora: prod_id es TEXT, no
-- uuid. El contrato de esta función usa jsonb precisamente para no tener que
-- tipar cada campo por separado, pero el CAST interno (item->>'prod_id',
-- sin ::uuid) refleja este tipo real.
--
-- DISEÑO (equivalente en garantías a fn_eliminar_compra_atomica de HITO
-- 6.18.9, mismo autor de diseño, mismos principios):
--  - SELECT ... FOR UPDATE sobre la compra: bloqueo real de Postgres. Una
--    segunda llamada concurrente sobre la MISMA compra espera aquí (no falla
--    con "0 filas" como el CAS de aplicación actual — espera, y al reanudar
--    relee el estado ya actualizado).
--  - Reconstruye unidades físicas desde compras_items (agrupadas por
--    prod_id), nunca confía en datos recalculados en el frontend.
--  - uds_empaque SIEMPRE se lee fresco del producto maestro (inventario),
--    bloqueado con FOR UPDATE, nunca de compras_items.uds_empaque (que
--    describe la presentación de LA COMPRA, no la configuración actual del
--    producto) — mismo principio ya validado en HITO 6.18.6/6.18.7/6.18.8.
--  - Orden determinístico ORDER BY prod_id al iterar productos: evita
--    deadlocks entre dos RPC concurrentes (p.ej. esta función recibiendo la
--    compra A mientras fn_eliminar_compra_atomica revierte la compra B, si
--    ambas tocan los mismos productos en órdenes distintos). HALLAZGO: el
--    archivo de 6.18.9 no tiene este ORDER BY explícito en su FOR..GROUP BY;
--    se documenta como mejora recomendada para ese archivo en el informe de
--    esta fase, pero NO SE MODIFICA ese archivo (protegido).
--  - CUALQUIER fallo usa RAISE EXCEPTION — nunca RETURN con jsonb de error.
--    Solo una excepción sin capturar fuerza ROLLBACK automático de TODA la
--    función.
--  - Multi-tenant: valida id_licencia en compras, inventario, inventario_bodega,
--    bodegas — igual que el resto de la aplicación actual.
--  - lock_timeout local: evita que una espera por FOR UPDATE quede colgada
--    indefinidamente si otra transacción nunca termina; expira con SQLSTATE
--    55P03, que se recaptura y se re-lanza como LC007 CONCURRENCIA con un
--    mensaje legible.
--
-- SECURITY INVOKER (decisión explícita, NO por defecto de PostgreSQL sino
-- razonada — ver sección "SEGURIDAD" del informe de Fase 2):
--  - Esta función NO se declara SECURITY DEFINER. Se ejecuta con los
--    privilegios del rol que la invoca (el rol "anon" de PostgREST, el mismo
--    que usa hoy la aplicación para hacer POST/PATCH/DELETE directos sobre
--    compras, compras_items e inventario).
--  - Evidencia de que el rol anon YA tiene los privilegios necesarios: la
--    aplicación actual, en producción, ejecuta exactamente estas operaciones
--    (INSERT/UPDATE/DELETE sobre estas mismas tablas) usando solo la anon
--    key, sin ningún error de permisos, en cientos de operaciones ya
--    auditadas en hitos anteriores. No se pudo confirmar esto consultando
--    metadatos de grants directamente (anon key no tiene acceso a esa
--    información — ver limitación ya documentada en Fase 1), pero la
--    evidencia de comportamiento real es consistente y repetida.
--  - Con SECURITY INVOKER, esta función NUNCA otorga a quien la invoque más
--    privilegio del que ya tiene por fuera de la función — es la opción de
--    mínimo privilegio. SECURITY DEFINER (usada en el archivo de 6.18.9)
--    otorga los privilegios del DUEÑO de la función sin importar quién la
--    invoque; es más potente pero también más riesgosa si el search_path o
--    los parámetros no se validan con cuidado. Dado que aquí no hace falta
--    ese poder adicional (el invocador ya puede hacer todo lo que la función
--    necesita), se prefiere INVOKER.
--  - SET search_path se define de todas formas (buena práctica defensiva,
--    no exclusiva de SECURITY DEFINER) para evitar resolución ambigua de
--    nombres de tabla no calificados.
-- ============================================================================

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

-- ============================================================================
-- Invocación futura desde el frontend (NO implementada todavía — ver 6.18.15
-- Fase 4, posterior a esta):
--
--   var r = await fetch(SB+'/rest/v1/rpc/recibir_compra_atomica', {
--     method: 'POST', headers: H,
--     body: JSON.stringify({ p_compra_id: id, p_id_licencia: CID })
--   });
--   if (!r.ok) { var err = await r.json(); toast(err.message); return; }
--   var data = await r.json(); // {ok:true, compra_id, estado:'recibida'}
--
-- Conectar recibirCompra() a esta RPC es un cambio de frontend fuera de
-- alcance de esta Fase 2 — debe hacerse en un hito posterior, DESPUÉS de que
-- esta función se aplique y se pruebe manualmente en Supabase.
-- ============================================================================
