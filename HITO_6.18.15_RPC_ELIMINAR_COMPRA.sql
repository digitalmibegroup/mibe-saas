-- ============================================================================
-- HITO 6.18.15 (Fase 2) — RPC transaccional para eliminación atómica de compras
-- ============================================================================
-- NO EJECUTADO. Ver cabecera de HITO_6.18.15_RPC_RECIBIR_COMPRA.sql para el
-- contexto completo sobre por qué este entorno no puede desplegar ni probar
-- esto contra una base real.
--
-- ORIGEN Y RELACIÓN CON HITO_6.18.9_rpc_eliminar_compra.sql
-- ============================================================================
-- Ya existe un diseño completo para esta operación: fn_eliminar_compra_atomica,
-- en HITO_6.18.9_rpc_eliminar_compra.sql (leído íntegro para esta auditoría,
-- NO modificado — ese archivo permanece intacto y protegido, como en todos
-- los hitos anteriores).
--
-- Ese diseño es CORRECTO en su garantía central: cualquier fallo usa
-- RAISE EXCEPTION, lo cual revierte automáticamente TODO lo hecho dentro de
-- la función (incluyendo UPDATEs ya aplicados a productos anteriores en el
-- mismo bucle) — la propiedad de "cero reversión parcial" que pide esta Fase
-- 2 (sección 27/38) YA se cumple en 6.18.9 por la semántica de PL/pgSQL, sin
-- necesidad de ningún cambio funcional.
--
-- Se crea este NUEVO archivo, con una función de nombre distinto
-- (eliminar_compra_atomica, sin el prefijo "fn_" del original) en vez de
-- reemplazar el de 6.18.9, por dos razones:
--   1. El archivo de 6.18.9 es un entregable ya revisado y NO debe tocarse
--      (regla explícita y repetida en todos los hitos de este batch).
--   2. Esta Fase 2 introduce 3 mejoras deliberadas, cada una justificada
--      abajo — son mejoras de robustez/estilo, NO correcciones de un bug:
--
--   MEJORA 1 — ORDER BY prod_id explícito en el bucle de productos.
--     HALLAZGO: el archivo de 6.18.9 itera "FOR v_item IN SELECT ...
--     GROUP BY ci.prod_id LOOP" SIN cláusula ORDER BY. PostgreSQL NO
--     garantiza ningún orden particular en la salida de un GROUP BY sin
--     ORDER BY explícito. Esto es un riesgo LATENTE de deadlock: si dos
--     transacciones concurrentes (p.ej. esta función eliminando la compra A
--     mientras recibir_compra_atomica procesa la compra B, y ambas compras
--     comparten productos) bloquean filas de "inventario" en órdenes
--     distintos e indeterminados, Postgres puede detectar un deadlock y
--     abortar una de las dos transacciones con SQLSTATE 40P01. No es un bug
--     de corrección (el resultado final sigue siendo atómico), pero SÍ es un
--     riesgo de disponibilidad (una operación legítima podría fallar por
--     deadlock en vez de simplemente esperar su turno). Esta nueva función
--     agrega "ORDER BY ci.prod_id" para que el orden de adquisición de locks
--     sea siempre el mismo (ascendente por prod_id) en las tres RPC de este
--     batch — la técnica estándar para evitar deadlocks por locking
--     multi-fila. Se documenta aquí como hallazgo para que, si se autoriza,
--     también pueda aplicarse como mejora al archivo de 6.18.9 en un hito
--     posterior (NO se modifica ese archivo en este hito).
--
--   MEJORA 2 — separación explícita en dos pasadas (validar todo, luego
--     escribir todo), en vez de validar-y-escribir por producto dentro del
--     mismo bucle. El resultado final es IDÉNTICO (por el ROLLBACK
--     automático de RAISE EXCEPTION), pero esta Fase 2 lo pide
--     explícitamente (sección 27: "cero reversión parcial... hacer todas las
--     validaciones primero y después todas las modificaciones") como
--     principio de diseño verificable por inspección del código, no solo
--     por conocer la semántica de PL/pgSQL. Se implementa aquí.
--
--   MEJORA 3 — SECURITY INVOKER en vez de SECURITY DEFINER (ver sección
--     "SEGURIDAD" más abajo) — decisión de mínimo privilegio, explícita para
--     esta Fase 2. El archivo de 6.18.9 usa SECURITY DEFINER; se documenta
--     la diferencia, no se cambia ese archivo.
--
-- Ninguna mejora altera: los tipos de parámetros (p_compra_id uuid,
-- p_id_licencia text — se re-verificaron y coinciden con el esquema real),
-- la fórmula del pool físico, ni la validación de suficiencia de inventario
-- ANTES de revertir.
--
-- HITO 6.18.15 Fase 8.1: los códigos originales P0001-P0004 de este archivo
-- (heredados del mismo esquema de nombres que 6.18.9) fueron renombrados a
-- LC010-LC013 porque colisionaban con condiciones internas reservadas de
-- PostgreSQL/PL/pgSQL (raise_exception, no_data_found, too_many_rows,
-- assert_failure respectivamente) — ver auditoría e informe de Fase 8/8.1.
-- P0005 (INVENTARIO_INSUFICIENTE) se mantiene sin cambios, sin colisión
-- conocida. Solo cambian los códigos; significado, mensajes, lógica, orden de
-- operaciones, locks y fórmulas permanecen exactamente iguales.
--
-- TIPOS REALES (re-verificados en Fase 2, iguales a los de 6.18.9):
--   compras.id uuid · compras.id_licencia text · compras_items.prod_id TEXT
--   (no uuid) · inventario.id TEXT · bodegas.id uuid.
-- ============================================================================

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

-- ============================================================================
-- Invocación futura desde el frontend (NO implementada todavía):
--
--   var r = await fetch(SB+'/rest/v1/rpc/eliminar_compra_atomica', {
--     method: 'POST', headers: H,
--     body: JSON.stringify({ p_compra_id: id, p_id_licencia: CID })
--   });
--   if (!r.ok) { var err = await r.json(); toast(err.message); return; }
--
-- Conectar eliminarCompra() a esta RPC es un cambio de frontend fuera de
-- alcance de esta Fase 2.
-- ============================================================================
