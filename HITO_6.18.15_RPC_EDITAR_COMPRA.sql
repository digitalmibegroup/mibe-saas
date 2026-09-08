-- ============================================================================
-- HITO 6.18.15 (Fase 2) — RPC transaccional para edición atómica de compras
-- ============================================================================
-- NO EJECUTADO. Ver cabecera de HITO_6.18.15_RPC_RECIBIR_COMPRA.sql para el
-- contexto completo sobre por qué este entorno no puede desplegar ni probar
-- esto contra una base real (sin psql/CLI/service_role — solo anon key).
--
-- OBJETIVO PRINCIPAL: cerrar la ventana de inconsistencia que hoy tiene
-- guardarEdicionCompra() en modo "completa" (compra pendiente):
--     DELETE compras_items
--     POST nuevos compras_items
--     PATCH compras (cabecera + estado)
-- son 3 llamadas HTTP separadas. Si el POST falla DESPUÉS del DELETE, la
-- compra queda sin productos (ni los viejos ni los nuevos) hasta revisión
-- manual. Esta función hace las tres operaciones en una sola transacción de
-- Postgres: si cualquier paso falla, los items ORIGINALES permanecen
-- exactamente como estaban — nunca hay un estado intermedio persistido.
--
-- TIPOS REALES (mismos verificados para la RPC de recepción):
--   p_compra_id     uuid
--   p_id_licencia   text
--   p_proveedor_id  uuid  (nullable — "Sin proveedor" es válido)
--   p_fecha         date
--   p_nota          text
--   p_destino       text  (solo relevante en modo 'completa')
--   p_items         jsonb (array de objetos; cada prod_id dentro es TEXT, no uuid)
--
-- POLÍTICA DE EDICIÓN (idéntica a politicaEdicionCompra() del frontend,
-- HITO 6.18.14-D — no se modifica esa política, se reimplementa server-side
-- para que sea la AUTORIDAD real, no solo una capa de UI):
--   pendiente  → modo 'completa'  (proveedor, fecha, nota, destino, items)
--   recibida   → modo 'limitada'  (solo proveedor, fecha, nota)
--   cualquier otro estado → bloqueado (ESTADO_INVALIDO)
--
-- VALIDACIÓN CRÍTICA DE "MODO" (HITO 6.18.15 Fase 1, sección 21/37): el modo
-- NUNCA se toma de lo que el cliente afirma (p_modo es una EXPECTATIVA del
-- cliente, no una orden). La función SIEMPRE deriva su propio v_modo desde
-- el estado real y bloqueado (v_compra.estado) y compara contra p_modo. Si
-- no coinciden (p.ej. el frontend renderizó el formulario completo para una
-- compra pendiente, pero otro proceso la recibió mientras el usuario
-- editaba), se aborta con ESTADO_INVALIDO — nunca se "adivina" ni se
-- procesa bajo el supuesto potencialmente obsoleto del cliente.
--
-- DOS PASADAS (validar todo, luego escribir todo) en modo 'completa': se
-- validan TODOS los items del array p_items ANTES de tocar compras_items —
-- si cualquiera es inválido, se aborta sin haber hecho ningún DELETE/INSERT,
-- así que "los items originales permanecen" es una propiedad verificable por
-- inspección del código (no solo una consecuencia indirecta del ROLLBACK
-- automático de PL/pgSQL, aunque ese ROLLBACK también lo garantizaría).
--
-- ESTA FUNCIÓN NUNCA TOCA:
--   inventario, inventario_bodega — ninguna sentencia UPDATE/INSERT/DELETE
--   sobre esas tablas existe en este archivo (verificable por grep — ver
--   auditoría en el informe de Fase 2). La edición de una compra (en
--   cualquier modo) no afecta inventario; solo la recepción lo hace.
--
-- SECURITY INVOKER — misma justificación que recibir_compra_atomica: el rol
-- anon ya realiza hoy, directamente vía REST, exactamente estas operaciones
-- (DELETE/POST/PATCH sobre compras y compras_items) sin error de permisos.
-- ============================================================================

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

-- ============================================================================
-- Invocación futura desde el frontend (NO implementada todavía):
--
--   var r = await fetch(SB+'/rest/v1/rpc/editar_compra_atomica', {
--     method: 'POST', headers: H,
--     body: JSON.stringify({
--       p_compra_id: _editCompraId,
--       p_id_licencia: CID,
--       p_modo: _editCompraModo,               -- lo que el cliente CREE que es
--       p_proveedor_id: proveedorSel || null,
--       p_fecha: fecha || null,
--       p_nota: nota,
--       p_destino: _editCompraModo==='completa' ? destino : null,
--       p_items: _editCompraModo==='completa'
--         ? _editCompraItems.map(function(i){return {prod_id:i.prod_id,nombre:i.nombre,qty:i.qty,costo:i.costo,tipo:i.tipo,uds_empaque:i.uds_empaque};})
--         : null
--     })
--   });
--   if (!r.ok) { var err = await r.json(); toast(err.message); return; }
--
-- Conectar guardarEdicionCompra() a esta RPC es un cambio de frontend fuera
-- de alcance de esta Fase 2.
-- ============================================================================
