-- ============================================================================
-- HITO 6.18.15 (Fase 2) — Pruebas SQL para las 3 RPC transaccionales
-- ============================================================================
-- ⚠ NO EJECUTADO EN ESTE HITO. Este archivo es un ENTREGABLE de diseño de
-- pruebas, redactado y auditado, pero NUNCA ejecutado contra Supabase real
-- desde este entorno (sin psql/CLI/service_role — ver cabecera de
-- HITO_6.18.15_RPC_RECIBIR_COMPRA.sql).
--
-- ⚠ REGLA ABSOLUTA: si en el futuro el propietario decide ejecutar este
-- archivo, debe hacerlo PRIMERO contra un proyecto/base de Supabase de
-- PRUEBA (sandbox), nunca contra producción. Aun en sandbox, todo el
-- contenido está envuelto en BEGIN; ... ROLLBACK; para que, incluso si se
-- ejecutara accidentalmente en el lugar equivocado, NINGÚN dato quede
-- persistido — el ROLLBACK final deshace absolutamente todo, incluidos los
-- datos de prueba (fixtures) creados al inicio.
--
-- FIXTURES: se usa un id_licencia claramente falso y reconocible
-- ('TEST_TENANT_618150') y prod_id/compra_id con prefijos de prueba, para
-- que sea imposible confundirlos con datos reales de 'lacava' incluso si el
-- ROLLBACK no ocurriera por alguna razón externa (p.ej. el proceso se corta
-- a la mitad) — es una segunda capa de seguridad, no una excusa para saltarse
-- el sandbox.
--
-- Requiere que las 3 funciones de este hito (recibir_compra_atomica,
-- editar_compra_atomica, eliminar_compra_atomica) ya existan en la base
-- donde se ejecute — es decir, requiere que los 3 archivos .sql anteriores
-- se hayan aplicado primero.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- FIXTURES: tenant de prueba, 2 productos, 1 bodega, y compras sintéticas.
-- --------------------------------------------------------------------------
DO $$
BEGIN
  INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, stock_min, empaque, uds_empaque, uds_sueltas, id_licencia)
  VALUES
    ('TEST_PROD_A_618150', 'Producto Test A', 'Test', 10000, 5000, 100, 2, 'unidad', 1, 0, 'TEST_TENANT_618150'),
    ('TEST_PROD_B_618150', 'Producto Test B', 'Test', 20000, 10000, 6,   2, 'sixpack', 6, 2, 'TEST_TENANT_618150'),
    ('TEST_PROD_C_618150', 'Producto Test C (para insuficiencia)', 'Test', 5000, 2000, 1, 1, 'unidad', 1, 0, 'TEST_TENANT_618150');

  INSERT INTO bodegas (id, id_licencia, nombre)
  VALUES ('11111111-1111-1111-1111-111111111111', 'TEST_TENANT_618150', 'Bodega Test 618150');
END $$;

-- ============================================================================
-- BLOQUE 1 — RECEPCIÓN: caso feliz, multi-producto, destino principal.
-- ============================================================================
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_result    jsonb;
  v_stock_a   integer;
  v_stock_b   integer;
  v_sueltas_b integer;
BEGIN
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 0, 'pendiente', 'principal');

  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES
    (v_compra_id, 'TEST_PROD_A_618150', 'Producto Test A', 10, 5000, 50000, 'unidad', 1),
    (v_compra_id, 'TEST_PROD_B_618150', 'Producto Test B', 2,  10000, 20000, 'sixpack', 6);
    -- unidades físicas esperadas: A = 10*1=10 · B = 2*6=12

  v_result := recibir_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  ASSERT (v_result->>'ok')::boolean = true, 'BLOQUE1: se esperaba ok=true';
  ASSERT (v_result->>'estado') = 'recibida', 'BLOQUE1: se esperaba estado=recibida';

  SELECT stock INTO v_stock_a FROM inventario WHERE id='TEST_PROD_A_618150';
  ASSERT v_stock_a = 110, format('BLOQUE1: stock A esperado 110, real %s', v_stock_a);

  SELECT stock, uds_sueltas INTO v_stock_b, v_sueltas_b FROM inventario WHERE id='TEST_PROD_B_618150';
  -- pool_actual B = 6*6+2=38 ; +12 = 50 ; 50/6=8 resto 2
  ASSERT v_stock_b = 8 AND v_sueltas_b = 2, format('BLOQUE1: stock/sueltas B esperado 8/2, real %s/%s', v_stock_b, v_sueltas_b);

  ASSERT (SELECT estado FROM compras WHERE id=v_compra_id) = 'recibida', 'BLOQUE1: compra debe quedar recibida';

  RAISE NOTICE 'BLOQUE 1 (recepcion feliz multi-producto): PASS';
END $$;

-- ============================================================================
-- BLOQUE 2 — RECEPCIÓN: doble llamada (idempotencia). La 2a debe fallar con
-- P0006 (COMPRA_YA_PROCESADA) y NO debe volver a sumar inventario.
-- ============================================================================
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_stock_antes integer;
  v_stock_despues integer;
  v_fallo boolean := false;
BEGIN
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 0, 'pendiente', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES (v_compra_id, 'TEST_PROD_A_618150', 'Producto Test A', 5, 5000, 25000, 'unidad', 1);

  PERFORM recibir_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  SELECT stock INTO v_stock_antes FROM inventario WHERE id='TEST_PROD_A_618150';

  BEGIN
    PERFORM recibir_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  EXCEPTION WHEN SQLSTATE 'P0006' THEN
    v_fallo := true;
  END;

  ASSERT v_fallo = true, 'BLOQUE2: la segunda recepcion debia fallar con P0006';
  SELECT stock INTO v_stock_despues FROM inventario WHERE id='TEST_PROD_A_618150';
  ASSERT v_stock_antes = v_stock_despues, format('BLOQUE2: el stock NO debia cambiar en el 2o intento (antes %s, despues %s)', v_stock_antes, v_stock_despues);

  RAISE NOTICE 'BLOQUE 2 (idempotencia / doble recepcion): PASS';
END $$;

-- ============================================================================
-- BLOQUE 3 — RECEPCIÓN: rollback ante producto inválido a mitad de camino.
-- Producto A (válido) + producto inexistente (inválido) en la MISMA compra.
-- Resultado esperado: NINGÚN producto queda modificado, compra sigue pendiente.
-- ============================================================================
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_stock_a_antes integer;
  v_stock_a_despues integer;
  v_fallo boolean := false;
BEGIN
  SELECT stock INTO v_stock_a_antes FROM inventario WHERE id='TEST_PROD_A_618150';

  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 0, 'pendiente', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES
    (v_compra_id, 'TEST_PROD_A_618150', 'Producto Test A', 3, 5000, 15000, 'unidad', 1),
    (v_compra_id, 'TEST_PROD_NO_EXISTE_618150', 'Producto Fantasma', 1, 1000, 1000, 'unidad', 1);
    -- ORDER BY prod_id procesa 'TEST_PROD_A...' antes que 'TEST_PROD_NO_EXISTE...'
    -- (A < N alfabeticamente) -- el producto A se bloquea/valida primero, y
    -- el fantasma falla despues: si el rollback NO funcionara, veriamos el
    -- stock de A ya incrementado. Este es exactamente el escenario que
    -- prueba que el ROLLBACK automatico de RAISE EXCEPTION deshace TODO,
    -- no solo lo que viene despues del fallo.

  BEGIN
    PERFORM recibir_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  EXCEPTION WHEN SQLSTATE 'LC013' THEN
    v_fallo := true;
  END;

  ASSERT v_fallo = true, 'BLOQUE3: se esperaba fallo LC013 (PRODUCTO_NO_EXISTE)';
  SELECT stock INTO v_stock_a_despues FROM inventario WHERE id='TEST_PROD_A_618150';
  ASSERT v_stock_a_antes = v_stock_a_despues, format('BLOQUE3: producto A NO debia quedar modificado (antes %s, despues %s)', v_stock_a_antes, v_stock_a_despues);
  ASSERT (SELECT estado FROM compras WHERE id=v_compra_id) = 'pendiente', 'BLOQUE3: la compra debe permanecer pendiente';

  RAISE NOTICE 'BLOQUE 3 (rollback recepcion con producto invalido): PASS';
END $$;

-- ============================================================================
-- BLOQUE 4 — RECEPCIÓN: destino bodega_secundaria, creación de fila nueva
-- en inventario_bodega dentro de la misma transacción.
-- ============================================================================
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_result jsonb;
  v_stock_bodega integer;
BEGIN
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 0, 'pendiente', 'bodega_secundaria');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES (v_compra_id, 'TEST_PROD_A_618150', 'Producto Test A', 20, 5000, 100000, 'unidad', 1);
  -- TEST_PROD_A_618150 aun no tiene fila en inventario_bodega para esta bodega.

  v_result := recibir_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  ASSERT (v_result->>'ok')::boolean = true, 'BLOQUE4: se esperaba ok=true';

  SELECT stock INTO v_stock_bodega FROM inventario_bodega
    WHERE id_licencia='TEST_TENANT_618150' AND id_bodega='11111111-1111-1111-1111-111111111111' AND prod_id='TEST_PROD_A_618150';
  ASSERT v_stock_bodega = 20, format('BLOQUE4: stock en bodega esperado 20, real %s', v_stock_bodega);

  RAISE NOTICE 'BLOQUE 4 (recepcion a bodega, fila nueva): PASS';
END $$;

-- ============================================================================
-- BLOQUE 5 — EDICIÓN completa (pendiente): agregar/quitar/cambiar items,
-- total recalculado, inventario SIN TOCAR.
-- ============================================================================
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_result jsonb;
  v_stock_a_antes integer;
  v_stock_a_despues integer;
  v_stock_b_antes integer;
  v_stock_b_despues integer;
  v_num_items integer;
  v_total integer;
BEGIN
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Original', CURRENT_DATE, 'nota original', 15000, 'pendiente', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES (v_compra_id, 'TEST_PROD_A_618150', 'Producto Test A', 3, 5000, 15000, 'unidad', 1);

  SELECT stock INTO v_stock_a_antes FROM inventario WHERE id='TEST_PROD_A_618150';
  SELECT stock INTO v_stock_b_antes FROM inventario WHERE id='TEST_PROD_B_618150';

  v_result := editar_compra_atomica(
    v_compra_id, 'TEST_TENANT_618150', 'completa',
    NULL, CURRENT_DATE, 'nota editada', 'principal',
    jsonb_build_array(
      jsonb_build_object('prod_id','TEST_PROD_A_618150','nombre','Producto Test A','qty',7,'costo',5000,'tipo','unidad','uds_empaque',1),
      jsonb_build_object('prod_id','TEST_PROD_B_618150','nombre','Producto Test B','qty',1,'costo',10000,'tipo','sixpack','uds_empaque',6)
    )
  );
  ASSERT (v_result->>'ok')::boolean = true, 'BLOQUE5: se esperaba ok=true';
  ASSERT (v_result->>'total')::integer = 45000, format('BLOQUE5: total esperado 45000 (7*5000+1*10000), real %s', v_result->>'total');

  SELECT count(*) INTO v_num_items FROM compras_items WHERE compra_id=v_compra_id;
  ASSERT v_num_items = 2, format('BLOQUE5: se esperaban 2 items, hay %s', v_num_items);

  SELECT total INTO v_total FROM compras WHERE id=v_compra_id;
  ASSERT v_total = 45000, format('BLOQUE5: compras.total esperado 45000, real %s', v_total);
  ASSERT (SELECT nota FROM compras WHERE id=v_compra_id) = 'nota editada', 'BLOQUE5: nota debia actualizarse';
  ASSERT (SELECT estado FROM compras WHERE id=v_compra_id) = 'pendiente', 'BLOQUE5: estado debe seguir pendiente';

  -- LA PRUEBA CRÍTICA: inventario NO debe haber cambiado, porque editar una
  -- compra pendiente jamás toca inventario.
  SELECT stock INTO v_stock_a_despues FROM inventario WHERE id='TEST_PROD_A_618150';
  SELECT stock INTO v_stock_b_despues FROM inventario WHERE id='TEST_PROD_B_618150';
  ASSERT v_stock_a_antes = v_stock_a_despues, 'BLOQUE5: inventario A NO debia cambiar al editar';
  ASSERT v_stock_b_antes = v_stock_b_despues, 'BLOQUE5: inventario B NO debia cambiar al editar';

  RAISE NOTICE 'BLOQUE 5 (edicion completa, inventario intacto): PASS';
END $$;

-- ============================================================================
-- BLOQUE 6 — EDICIÓN: rollback si un item del nuevo set es inválido. Los
-- items ORIGINALES deben permanecer exactamente igual.
-- ============================================================================
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_fallo boolean := false;
  v_num_items integer;
  v_qty_original integer;
BEGIN
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Original', CURRENT_DATE, '', 15000, 'pendiente', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES (v_compra_id, 'TEST_PROD_A_618150', 'Producto Test A', 3, 5000, 15000, 'unidad', 1);

  BEGIN
    PERFORM editar_compra_atomica(
      v_compra_id, 'TEST_TENANT_618150', 'completa',
      NULL, CURRENT_DATE, 'intento fallido', 'principal',
      jsonb_build_array(
        jsonb_build_object('prod_id','TEST_PROD_A_618150','nombre','Producto Test A','qty',9,'costo',5000,'tipo','unidad','uds_empaque',1),
        jsonb_build_object('prod_id','TEST_PROD_NO_EXISTE_618150','nombre','Fantasma','qty',1,'costo',1000,'tipo','unidad','uds_empaque',1)
      )
    );
  EXCEPTION WHEN SQLSTATE 'LC013' THEN
    v_fallo := true;
  END;

  ASSERT v_fallo = true, 'BLOQUE6: se esperaba fallo LC013';
  SELECT count(*), MAX(qty) INTO v_num_items, v_qty_original FROM compras_items WHERE compra_id=v_compra_id;
  ASSERT v_num_items = 1, format('BLOQUE6: debia seguir habiendo exactamente 1 item original, hay %s', v_num_items);
  ASSERT v_qty_original = 3, format('BLOQUE6: la qty original (3) debia permanecer intacta, es %s', v_qty_original);
  ASSERT (SELECT nota FROM compras WHERE id=v_compra_id) = '', 'BLOQUE6: la nota original debia permanecer (no "intento fallido")';

  RAISE NOTICE 'BLOQUE 6 (rollback edicion, items originales preservados): PASS';
END $$;

-- ============================================================================
-- BLOQUE 7 — EDICIÓN limitada (recibida): solo proveedor/fecha/nota, NUNCA
-- toca items/destino/total/inventario, aunque se le pasen items maliciosos.
-- ============================================================================
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_result jsonb;
  v_num_items_antes integer;
  v_num_items_despues integer;
  v_stock_a_antes integer;
  v_stock_a_despues integer;
BEGIN
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Original', CURRENT_DATE, '', 15000, 'recibida', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES (v_compra_id, 'TEST_PROD_A_618150', 'Producto Test A', 3, 5000, 15000, 'unidad', 1);

  SELECT count(*) INTO v_num_items_antes FROM compras_items WHERE compra_id=v_compra_id;
  SELECT stock INTO v_stock_a_antes FROM inventario WHERE id='TEST_PROD_A_618150';

  -- Se envían items intencionalmente (simulando un cliente malicioso o con
  -- bug) para confirmar que el modo 'limitada' los IGNORA por completo.
  v_result := editar_compra_atomica(
    v_compra_id, 'TEST_TENANT_618150', 'limitada',
    NULL, CURRENT_DATE, 'nota admin actualizada', 'bodega_secundaria',
    jsonb_build_array(jsonb_build_object('prod_id','TEST_PROD_A_618150','nombre','x','qty',999,'costo',1,'tipo','unidad','uds_empaque',1))
  );
  ASSERT (v_result->>'ok')::boolean = true, 'BLOQUE7: se esperaba ok=true';
  ASSERT (SELECT nota FROM compras WHERE id=v_compra_id) = 'nota admin actualizada', 'BLOQUE7: nota SI debia actualizarse';
  ASSERT (SELECT destino FROM compras WHERE id=v_compra_id) = 'principal', 'BLOQUE7: destino NO debia cambiar (se ignoro bodega_secundaria)';
  ASSERT (SELECT total FROM compras WHERE id=v_compra_id) = 15000, 'BLOQUE7: total NO debia cambiar';
  ASSERT (SELECT estado FROM compras WHERE id=v_compra_id) = 'recibida', 'BLOQUE7: estado debe seguir recibida';

  SELECT count(*) INTO v_num_items_despues FROM compras_items WHERE compra_id=v_compra_id;
  ASSERT v_num_items_antes = v_num_items_despues, 'BLOQUE7: items NO debian cambiar en modo limitada';

  SELECT stock INTO v_stock_a_despues FROM inventario WHERE id='TEST_PROD_A_618150';
  ASSERT v_stock_a_antes = v_stock_a_despues, 'BLOQUE7: inventario NO debia cambiar en modo limitada';

  RAISE NOTICE 'BLOQUE 7 (edicion limitada, items ignorados, inventario intacto): PASS';
END $$;

-- ============================================================================
-- BLOQUE 8 — EDICIÓN: mismatch de modo (el cliente cree 'completa' pero la
-- compra ya está 'recibida'). Debe fallar sin aplicar ningún cambio.
-- ============================================================================
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_fallo boolean := false;
BEGIN
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Original', CURRENT_DATE, 'nota sin tocar', 15000, 'recibida', 'principal');

  BEGIN
    PERFORM editar_compra_atomica(
      v_compra_id, 'TEST_TENANT_618150', 'completa',  -- el cliente cree que es pendiente
      NULL, CURRENT_DATE, 'esto no debe aplicarse', 'principal', '[]'::jsonb
    );
  EXCEPTION WHEN SQLSTATE 'LC010' THEN
    v_fallo := true;
  END;

  ASSERT v_fallo = true, 'BLOQUE8: se esperaba fallo LC010 por mismatch de modo';
  ASSERT (SELECT nota FROM compras WHERE id=v_compra_id) = 'nota sin tocar', 'BLOQUE8: la nota NO debia cambiar';

  RAISE NOTICE 'BLOQUE 8 (mismatch de modo en edicion): PASS';
END $$;

-- ============================================================================
-- BLOQUE 9 — ELIMINACIÓN: caso feliz, un producto, destino principal.
-- ============================================================================
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_result jsonb;
  v_stock_antes integer;
  v_stock_despues integer;
BEGIN
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 25000, 'recibida', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES (v_compra_id, 'TEST_PROD_A_618150', 'Producto Test A', 5, 5000, 25000, 'unidad', 1);

  SELECT stock INTO v_stock_antes FROM inventario WHERE id='TEST_PROD_A_618150';
  v_result := eliminar_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  ASSERT (v_result->>'ok')::boolean = true, 'BLOQUE9: se esperaba ok=true';

  SELECT stock INTO v_stock_despues FROM inventario WHERE id='TEST_PROD_A_618150';
  ASSERT v_stock_despues = v_stock_antes - 5, format('BLOQUE9: stock esperado %s, real %s', v_stock_antes-5, v_stock_despues);
  ASSERT NOT EXISTS (SELECT 1 FROM compras WHERE id=v_compra_id), 'BLOQUE9: la compra debia eliminarse';
  ASSERT NOT EXISTS (SELECT 1 FROM compras_items WHERE compra_id=v_compra_id), 'BLOQUE9: los items debian eliminarse';

  RAISE NOTICE 'BLOQUE 9 (eliminacion feliz): PASS';
END $$;

-- ============================================================================
-- BLOQUE 10 — ELIMINACIÓN: rollback ante inventario insuficiente en el
-- SEGUNDO producto. El PRIMER producto (que sí tenía inventario suficiente)
-- NO debe revertirse — cero reversión parcial.
-- ============================================================================
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_stock_a_antes integer;
  v_stock_a_despues integer;
  v_stock_c_antes integer;
  v_stock_c_despues integer;
  v_fallo boolean := false;
BEGIN
  -- TEST_PROD_C_618150 tiene stock=1 (fixture inicial). Se arma una compra
  -- que reclama revertir 5 unidades de C (imposible) junto con A (posible),
  -- para demostrar que A NO se toca aunque C falle DESPUES en el orden
  -- alfabetico (A < C).
  SELECT stock INTO v_stock_a_antes FROM inventario WHERE id='TEST_PROD_A_618150';
  SELECT stock INTO v_stock_c_antes FROM inventario WHERE id='TEST_PROD_C_618150';

  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 0, 'recibida', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES
    (v_compra_id, 'TEST_PROD_A_618150', 'Producto Test A', 2, 5000, 10000, 'unidad', 1),
    (v_compra_id, 'TEST_PROD_C_618150', 'Producto Test C', 5, 2000, 10000, 'unidad', 1);
    -- revertir 5 de C cuando C solo tiene stock=1 -> INVENTARIO_INSUFICIENTE

  BEGIN
    PERFORM eliminar_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  EXCEPTION WHEN SQLSTATE 'P0005' THEN
    v_fallo := true;
  END;

  ASSERT v_fallo = true, 'BLOQUE10: se esperaba fallo P0005 (INVENTARIO_INSUFICIENTE)';

  SELECT stock INTO v_stock_a_despues FROM inventario WHERE id='TEST_PROD_A_618150';
  SELECT stock INTO v_stock_c_despues FROM inventario WHERE id='TEST_PROD_C_618150';
  ASSERT v_stock_a_antes = v_stock_a_despues, 'BLOQUE10: producto A (suficiente) NO debia revertirse';
  ASSERT v_stock_c_antes = v_stock_c_despues, 'BLOQUE10: producto C (insuficiente) NO debia revertirse';
  ASSERT (SELECT estado FROM compras WHERE id=v_compra_id) = 'recibida', 'BLOQUE10: la compra debe permanecer recibida';
  ASSERT EXISTS (SELECT 1 FROM compras_items WHERE compra_id=v_compra_id), 'BLOQUE10: los items NO debian borrarse';

  RAISE NOTICE 'BLOQUE 10 (rollback eliminacion, cero reversion parcial): PASS';
END $$;

-- ============================================================================
-- NOTA SOBRE PRUEBAS DE CONCURRENCIA REAL (bloques 11-13 del plan de pruebas
-- de Fase 1, sección 23): un script SQL de una sola sesión/conexión NO puede
-- ejercitar "dos llamadas verdaderamente simultáneas" — eso requiere dos
-- conexiones separadas ejecutando en paralelo (p.ej. dos pestañas de psql, o
-- dos workers), coordinadas para que la Sesión B intente su SELECT ... FOR
-- UPDATE mientras la Sesión A todavía no ha hecho COMMIT. Esto NO se incluye
-- en este archivo porque:
--   1. Requeriría abrir una segunda conexión real a Supabase, que este
--      entorno no tiene forma de hacer (ver limitación de acceso ya
--      documentada).
--   2. Simularlo con pg_sleep() dentro de un solo script no demuestra el
--      bloqueo real de FOR UPDATE, solo una demora artificial.
-- Queda documentado como PENDIENTE para la Fase 3 (sección "5. Browser con
-- datos controlados" / "6. Pruebas de concurrencia" del plan de migración de
-- Fase 1) — debe ejecutarse manualmente con dos sesiones psql reales contra
-- el sandbox, una vez exista acceso a él.
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== TODOS LOS BLOQUES DE PRUEBA (1-10) COMPLETADOS ===';
END $$;

ROLLBACK;
-- El ROLLBACK final deshace absolutamente todo lo anterior: fixtures,
-- compras de prueba, cambios de inventario de prueba. Nada de este archivo
-- persiste, incluso si se ejecuta completo y todas las pruebas pasan.
