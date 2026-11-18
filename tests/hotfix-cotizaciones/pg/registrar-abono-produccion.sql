-- Definicion EXACTA de produccion (lectura de catalogo del 16-nov-2026), solo para pruebas locales.
CREATE OR REPLACE FUNCTION public.registrar_abono_cartera_atomico(p_cartera_id uuid, p_id_licencia text, p_monto numeric, p_fecha timestamp with time zone, p_medio_pago text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c_tol           constant numeric := 0.5;   -- misma tolerancia que TOL_CARTERA del frontend
  v_cartera       record;
  v_venta         record;
  v_suma          numeric;
  v_abono_venta   numeric;
  v_espejo        boolean;
  v_recibido      numeric;
  v_saldo_calc    numeric;
  v_saldo_ant     numeric;
  v_saldo_nuevo   numeric;
  v_estado_nuevo  text;
  v_abono_id      uuid;
  v_suma_post     numeric;
BEGIN
  -- BLOQUE 2.5-B.2-FINAL: producción fija anon.statement_timeout = 3s (confirmado en
  -- catálogo real). Un lock_timeout de 10s nunca se alcanzaría — la plataforma cortaría
  -- antes con un 57014 genérico. Se baja a 2s para que, ante contención real, el error
  -- propio de esta función (LC027, con mensaje claro y el mismo rollback transaccional
  -- ya probado) se dispare primero.
  SET LOCAL lock_timeout = '2s';

  -- 0) Validación de parámetros (antes de bloquear nada).
  IF p_monto IS NULL OR p_monto <= 0 THEN
    RAISE EXCEPTION 'El valor del abono no es válido (debe ser mayor que 0).' USING ERRCODE = 'LC020';
  END IF;
  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'La fecha del abono no es válida.' USING ERRCODE = 'LC028';
  END IF;
  IF p_medio_pago IS NULL OR p_medio_pago NOT IN ('efectivo', 'transferencia', 'nequi', 'daviplata') THEN
    RAISE EXCEPTION 'El medio de pago del abono no es válido.' USING ERRCODE = 'LC029';
  END IF;

  -- 1) Bloquear la cartera del tenant.
  SELECT * INTO v_cartera
    FROM cartera
    WHERE id = p_cartera_id AND id_licencia = p_id_licencia
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La cartera no existe o no pertenece a este tenant.' USING ERRCODE = 'LC021';
  END IF;

  -- 2) Venta asociada, del mismo tenant, bloqueada en modo compartido.
  SELECT id, total, abono, estado INTO v_venta
    FROM ventas
    WHERE id = v_cartera.venta_id AND id_cliente = p_id_licencia
    FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La venta asociada a esta cartera no existe o no pertenece a este tenant.' USING ERRCODE = 'LC022';
  END IF;
  IF v_venta.estado IS DISTINCT FROM 'credito' THEN
    RAISE EXCEPTION 'La venta asociada no es una venta a crédito.' USING ERRCODE = 'LC022';
  END IF;

  -- 3) Dinero recibido: todos los abonos + el abono inicial de la venta SOLO si
  --    su fila espejo no existe ya en cartera_abonos (nunca se cuenta dos veces).
  SELECT COALESCE(SUM(monto), 0) INTO v_suma FROM cartera_abonos WHERE cartera_id = v_cartera.id;
  v_abono_venta := COALESCE(v_venta.abono, 0);
  v_espejo := v_abono_venta > 0 AND EXISTS (
    SELECT 1 FROM cartera_abonos a
     WHERE a.cartera_id = v_cartera.id
       AND round(a.monto) = round(v_abono_venta)
       AND (a.fecha = v_cartera.fecha_creacion
            OR abs(extract(epoch FROM (a.fecha - v_cartera.fecha_creacion))) <= 60
            OR abs(extract(epoch FROM (a.created_at - v_cartera.created_at))) <= 60));
  v_recibido   := v_suma + CASE WHEN v_abono_venta > 0 AND NOT v_espejo THEN v_abono_venta ELSE 0 END;
  v_saldo_calc := greatest(0, v_cartera.total - v_recibido);
  v_saldo_ant  := COALESCE(v_cartera.saldo_pendiente, 0);

  -- 4) Pendiente de conciliación histórica (mismos criterios que diagnosticarCartera()).
  IF abs(COALESCE(v_venta.total, 0) - v_cartera.total) > c_tol THEN
    RAISE EXCEPTION 'Cartera pendiente de conciliación histórica: el total de la cartera no coincide con el de la venta.' USING ERRCODE = 'LC023';
  END IF;
  IF v_abono_venta > 0 AND NOT v_espejo THEN
    RAISE EXCEPTION 'Cartera pendiente de conciliación histórica: el abono inicial de la venta no está en el historial de abonos.' USING ERRCODE = 'LC023';
  END IF;
  IF v_recibido - v_cartera.total > c_tol THEN
    RAISE EXCEPTION 'Cartera pendiente de conciliación histórica: los abonos registrados superan el total de la venta.' USING ERRCODE = 'LC023';
  END IF;
  IF abs(v_saldo_ant - v_saldo_calc) > c_tol THEN
    RAISE EXCEPTION 'Cartera pendiente de conciliación histórica: el saldo guardado no coincide con el historial de abonos.' USING ERRCODE = 'LC023';
  END IF;
  IF v_cartera.estado_cartera IS DISTINCT FROM (CASE WHEN v_saldo_ant <= c_tol THEN 'pagada' ELSE 'activa' END) THEN
    RAISE EXCEPTION 'Cartera pendiente de conciliación histórica: el estado no coincide con el saldo.' USING ERRCODE = 'LC023';
  END IF;

  -- 5) Estado y monto.
  IF v_saldo_ant <= c_tol THEN
    RAISE EXCEPTION 'Esta cuenta ya está en PAZ Y SALVO — no se registró ningún abono.' USING ERRCODE = 'LC024';
  END IF;
  IF p_monto > v_saldo_calc + c_tol THEN
    RAISE EXCEPTION 'El abono (%) supera el saldo pendiente real (%).', p_monto, v_saldo_calc USING ERRCODE = 'LC025';
  END IF;

  -- 6) Escribir: abono + saldo/estado, en la misma transacción.
  INSERT INTO cartera_abonos (id_licencia, cartera_id, venta_id, monto, fecha, registrado_por, medio_pago)
    VALUES (p_id_licencia, v_cartera.id, v_cartera.venta_id, p_monto, p_fecha, 'pos', p_medio_pago)
    RETURNING id INTO v_abono_id;

  v_saldo_nuevo := greatest(0, v_cartera.total - (v_recibido + p_monto));
  IF v_saldo_nuevo <= c_tol THEN
    v_saldo_nuevo  := 0;
    v_estado_nuevo := 'pagada';
  ELSE
    v_estado_nuevo := 'activa';
  END IF;

  UPDATE cartera
     SET saldo_pendiente = v_saldo_nuevo, estado_cartera = v_estado_nuevo, updated_at = now()
   WHERE id = v_cartera.id AND id_licencia = p_id_licencia;

  -- 7) Invariante final, releído de la base: saldo = total − dinero recibido.
  SELECT COALESCE(SUM(monto), 0) INTO v_suma_post FROM cartera_abonos WHERE cartera_id = v_cartera.id;
  IF abs(v_suma_post - (v_suma + p_monto)) > c_tol
     OR abs(v_saldo_nuevo - greatest(0, v_cartera.total - v_suma_post)) > c_tol
     OR v_saldo_nuevo < 0 THEN
    RAISE EXCEPTION 'Verificación final fallida: el saldo no coincide con los abonos registrados. No se guardó nada.' USING ERRCODE = 'LC026';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'cartera_id', v_cartera.id,
    'venta_id', v_cartera.venta_id,
    'abono_id', v_abono_id,
    'saldo_anterior', v_saldo_ant,
    'abono_registrado', p_monto,
    'saldo_nuevo', v_saldo_nuevo,
    'estado_nuevo', v_estado_nuevo,
    'total', v_cartera.total,
    'recibido_total', v_recibido + p_monto);

EXCEPTION
  WHEN lock_not_available THEN
    RAISE EXCEPTION 'No se pudo obtener acceso exclusivo a esta cartera a tiempo (otra operación está en curso) — inténtalo de nuevo.'
      USING ERRCODE = 'LC027';
END;
$function$
;
REVOKE ALL ON FUNCTION public.registrar_abono_cartera_atomico(uuid,text,numeric,timestamptz,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_abono_cartera_atomico(uuid,text,numeric,timestamptz,text) TO anon, authenticated;
