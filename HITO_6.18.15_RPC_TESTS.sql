-- ============================================================================
-- HITO 6.18.15 (Fase 2) — Pruebas SQL para las 3 RPC transaccionales
-- ============================================================================
-- ESTADO (HITO 3.7): ejecutado en un PostgreSQL 17.11 LOCAL de pruebas
-- (base "lacava_staging", nunca en Supabase): bloques 1-10 y S1-S7 => 17/17 PASS
-- contra las 3 RPC corregidas para compras_items.sueltas. S5-S6 (HITO 3.7):
-- el subtotal de editar_compra_atomica incluye el valor de las sueltas. S7: una
-- línea de editar_compra_atomica es válida si qty > 0 OR sueltas > 0 (qty=0 con
-- sueltas>0 = solo unidades sueltas).
-- Texto original de este hito, conservado: ⚠ este archivo es un ENTREGABLE de
-- diseño de pruebas y NO debe ejecutarse contra Supabase real (sin
-- psql/CLI/service_role desde el entorno de trabajo — ver cabecera de
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
-- HITO 3.7 — BLOQUES S1-S4: compras_items.sueltas (integer NOT NULL DEFAULT 0).
-- Cada bloque crea su propio producto (uds_empaque=6), así que no depende del
-- estado que hayan dejado los bloques anteriores dentro de esta transacción.
-- Requieren que compras_items.sueltas exista (HITO_3.6.1_MIGRACION_SUELTAS.sql).
-- ============================================================================

-- BLOQUE S1 — SUELTAS A: qty=6, uds_empaque=6, sueltas=4 => 40 unidades físicas.
--             Recepción: +40. Eliminación: -40 (vuelve exactamente al inicio).
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_pool_antes integer; v_pool_rec integer; v_pool_elim integer;
  v_stock integer; v_sueltas integer;
BEGIN
  INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, stock_min, empaque, uds_empaque, uds_sueltas, id_licencia)
  VALUES ('TEST_PROD_SUE_A_618150', 'Producto Test Sueltas A', 'Test', 1000, 1000, 10, 2, 'unidad', 6, 1, 'TEST_TENANT_618150');
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 800000, 'pendiente', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque, sueltas)
  VALUES (v_compra_id, 'TEST_PROD_SUE_A_618150', 'Producto Test Sueltas A', 6, 120000, 800000, 'unidad', 6, 4);

  SELECT stock*uds_empaque+uds_sueltas INTO v_pool_antes FROM inventario WHERE id='TEST_PROD_SUE_A_618150';  -- 61
  PERFORM recibir_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  SELECT stock*uds_empaque+uds_sueltas, stock, uds_sueltas INTO v_pool_rec, v_stock, v_sueltas FROM inventario WHERE id='TEST_PROD_SUE_A_618150';
  ASSERT v_pool_rec - v_pool_antes = 40, format('S1: recepcion esperada +40, real +%s', v_pool_rec - v_pool_antes);
  ASSERT v_stock = 16 AND v_sueltas = 5, format('S1: stock/sueltas esperado 16/5, real %s/%s', v_stock, v_sueltas);
  ASSERT (SELECT estado FROM compras WHERE id=v_compra_id) = 'recibida', 'S1: la compra debe quedar recibida';

  PERFORM eliminar_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  SELECT stock*uds_empaque+uds_sueltas, stock, uds_sueltas INTO v_pool_elim, v_stock, v_sueltas FROM inventario WHERE id='TEST_PROD_SUE_A_618150';
  ASSERT v_pool_rec - v_pool_elim = 40, format('S1: eliminacion esperada -40, real -%s', v_pool_rec - v_pool_elim);
  ASSERT v_pool_elim = v_pool_antes AND v_stock = 10 AND v_sueltas = 1, format('S1: debe volver EXACTAMENTE al inicio (10/1), real %s/%s', v_stock, v_sueltas);
  ASSERT NOT EXISTS (SELECT 1 FROM compras WHERE id=v_compra_id), 'S1: la compra debia eliminarse';

  RAISE NOTICE 'BLOQUE S1 (sueltas A: qty=6,uds=6,sueltas=4 => +40 / -40): PASS';
END $$;

-- BLOQUE S2 — SUELTAS B: qty=5, uds_empaque=6, sueltas=2 => 32 unidades físicas.
--             Recepción: +32. Eliminación: -32.
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_pool_antes integer; v_pool_rec integer; v_pool_elim integer;
  v_stock integer; v_sueltas integer;
BEGIN
  INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, stock_min, empaque, uds_empaque, uds_sueltas, id_licencia)
  VALUES ('TEST_PROD_SUE_B_618150', 'Producto Test Sueltas B', 'Test', 1000, 1000, 10, 2, 'unidad', 6, 1, 'TEST_TENANT_618150');
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 640000, 'pendiente', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque, sueltas)
  VALUES (v_compra_id, 'TEST_PROD_SUE_B_618150', 'Producto Test Sueltas B', 5, 120000, 640000, 'unidad', 6, 2);

  SELECT stock*uds_empaque+uds_sueltas INTO v_pool_antes FROM inventario WHERE id='TEST_PROD_SUE_B_618150';  -- 61
  PERFORM recibir_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  SELECT stock*uds_empaque+uds_sueltas, stock, uds_sueltas INTO v_pool_rec, v_stock, v_sueltas FROM inventario WHERE id='TEST_PROD_SUE_B_618150';
  ASSERT v_pool_rec - v_pool_antes = 32, format('S2: recepcion esperada +32, real +%s', v_pool_rec - v_pool_antes);
  ASSERT v_stock = 15 AND v_sueltas = 3, format('S2: stock/sueltas esperado 15/3, real %s/%s', v_stock, v_sueltas);

  PERFORM eliminar_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  SELECT stock*uds_empaque+uds_sueltas, stock, uds_sueltas INTO v_pool_elim, v_stock, v_sueltas FROM inventario WHERE id='TEST_PROD_SUE_B_618150';
  ASSERT v_pool_rec - v_pool_elim = 32, format('S2: eliminacion esperada -32, real -%s', v_pool_rec - v_pool_elim);
  ASSERT v_pool_elim = v_pool_antes AND v_stock = 10 AND v_sueltas = 1, format('S2: debe volver EXACTAMENTE al inicio (10/1), real %s/%s', v_stock, v_sueltas);

  RAISE NOTICE 'BLOQUE S2 (sueltas B: qty=5,uds=6,sueltas=2 => +32 / -32): PASS';
END $$;

-- BLOQUE S3 — ELIMINACIÓN: la VALIDACIÓN previa también considera sueltas.
--             Compra recibida de 40 unidades físicas (qty=6, sueltas=4). El
--             inventario tiene solo 38 (más que 36 = qty*uds_empaque, menos
--             que 40): con la fórmula anterior (sin sueltas) la validación
--             pasaba y se revertía de menos; ahora debe rechazarse con P0005
--             sin tocar nada.
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_fallo boolean := false;
  v_stock integer; v_sueltas integer;
BEGIN
  INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, stock_min, empaque, uds_empaque, uds_sueltas, id_licencia)
  VALUES ('TEST_PROD_SUE_C_618150', 'Producto Test Sueltas C', 'Test', 1000, 1000, 6, 2, 'unidad', 6, 2, 'TEST_TENANT_618150');  -- pool = 38
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 800000, 'recibida', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque, sueltas)
  VALUES (v_compra_id, 'TEST_PROD_SUE_C_618150', 'Producto Test Sueltas C', 6, 120000, 800000, 'unidad', 6, 4);

  BEGIN
    PERFORM eliminar_compra_atomica(v_compra_id, 'TEST_TENANT_618150');
  EXCEPTION WHEN SQLSTATE 'P0005' THEN
    v_fallo := true;
  END;

  ASSERT v_fallo = true, 'S3: se esperaba P0005 (38 < 40 unidades fisicas a revertir)';
  SELECT stock, uds_sueltas INTO v_stock, v_sueltas FROM inventario WHERE id='TEST_PROD_SUE_C_618150';
  ASSERT v_stock = 6 AND v_sueltas = 2, format('S3: el inventario NO debia tocarse (6/2), real %s/%s', v_stock, v_sueltas);
  ASSERT (SELECT estado FROM compras WHERE id=v_compra_id) = 'recibida', 'S3: la compra debe permanecer recibida';
  ASSERT EXISTS (SELECT 1 FROM compras_items WHERE compra_id=v_compra_id), 'S3: los items NO debian borrarse';

  RAISE NOTICE 'BLOQUE S3 (eliminacion: la validacion previa considera sueltas, 38 < 40 => rechazada): PASS';
END $$;

-- BLOQUE S4 — EDICIÓN: persiste sueltas. (a) sueltas=5 se guarda tal cual;
--             (b) un item SIN la clave "sueltas" sigue funcionando y queda en
--             0 (compatibilidad); (c) sueltas negativa se rechaza (LC005) y
--             los items originales se conservan; (d) el inventario no se toca.
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_pool_antes integer; v_pool_despues integer;
  v_fallo boolean := false;
BEGIN
  INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, stock_min, empaque, uds_empaque, uds_sueltas, id_licencia)
  VALUES ('TEST_PROD_SUE_D_618150', 'Producto Test Sueltas D', 'Test', 1000, 1000, 10, 2, 'unidad', 6, 1, 'TEST_TENANT_618150');
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 0, 'pendiente', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES (v_compra_id, 'TEST_PROD_SUE_D_618150', 'Producto Test Sueltas D', 6, 120000, 720000, 'unidad', 6);
  ASSERT (SELECT sueltas FROM compras_items WHERE compra_id=v_compra_id) = 0, 'S4: un INSERT sin sueltas debe quedar en 0 (DEFAULT)';

  SELECT stock*uds_empaque+uds_sueltas INTO v_pool_antes FROM inventario WHERE id='TEST_PROD_SUE_D_618150';

  -- (a) sueltas = 5
  PERFORM editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_SUE_D_618150","nombre":"Producto Test Sueltas D","qty":13,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":5}]'::jsonb);
  ASSERT (SELECT sueltas FROM compras_items WHERE compra_id=v_compra_id) = 5, 'S4a: compras_items.sueltas debia quedar en 5';
  ASSERT (SELECT qty FROM compras_items WHERE compra_id=v_compra_id) = 13, 'S4a: qty debia quedar en 13';
  ASSERT (SELECT estado FROM compras WHERE id=v_compra_id) = 'pendiente', 'S4a: la compra sigue pendiente';

  -- (b) item sin la clave "sueltas" => 0
  PERFORM editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_SUE_D_618150","nombre":"Producto Test Sueltas D","qty":7,"costo":120000,"tipo":"unidad","uds_empaque":6}]'::jsonb);
  ASSERT (SELECT sueltas FROM compras_items WHERE compra_id=v_compra_id) = 0, 'S4b: sin la clave sueltas debia quedar en 0';
  ASSERT (SELECT qty FROM compras_items WHERE compra_id=v_compra_id) = 7, 'S4b: qty debia quedar en 7';

  -- (c) sueltas negativa => LC005, items previos intactos
  BEGIN
    PERFORM editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
      '[{"prod_id":"TEST_PROD_SUE_D_618150","nombre":"Producto Test Sueltas D","qty":9,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":-1}]'::jsonb);
  EXCEPTION WHEN SQLSTATE 'LC005' THEN
    v_fallo := true;
  END;
  ASSERT v_fallo = true, 'S4c: se esperaba LC005 por sueltas negativa';
  ASSERT (SELECT qty FROM compras_items WHERE compra_id=v_compra_id) = 7 AND (SELECT count(*) FROM compras_items WHERE compra_id=v_compra_id) = 1,
    'S4c: los items originales debian conservarse (qty=7, 1 fila)';

  -- (d) el inventario no se toca en ningun modo de edicion
  SELECT stock*uds_empaque+uds_sueltas INTO v_pool_despues FROM inventario WHERE id='TEST_PROD_SUE_D_618150';
  ASSERT v_pool_antes = v_pool_despues, 'S4d: editar NO debe modificar inventario';

  RAISE NOTICE 'BLOQUE S4 (edicion: sueltas=5 persiste, sin clave => 0, negativa rechazada, inventario intacto): PASS';
END $$;

-- BLOQUE S5 — SUBTOTAL DE editar_compra_atomica INCLUYE EL VALOR DE LAS SUELTAS
--             subtotal = qty × costo + sueltas × costo / uds_empaque
--             (sin redondeo; el subtotal se compara como TEXTO para detectar
--             también ceros de relleno tipo 800000.0000000000000000).
--             T1 sueltas=0 (regla vieja, idéntica)       T5 uds_empaque=1 (caso defensivo)
--             T2 sueltas=4, costo redondo                T6 sueltas negativa => LC005
--             T3 costo NO divisible por uds_empaque      T7 sueltas ausente / null => 0
--             T4 costo con división exacta a 806000      T8 total = suma de items (mixto)
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_pool_antes integer; v_pool_despues integer;
  v_fallo boolean := false;
  v_st text; v_tot text; v_sue integer; v_ret text;
BEGIN
  INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, stock_min, empaque, uds_empaque, uds_sueltas, id_licencia)
  VALUES ('TEST_PROD_SUB_618150', 'Producto Test Subtotal', 'Test', 1000, 1000, 10, 2, 'unidad', 6, 1, 'TEST_TENANT_618150'),
         ('TEST_PROD_SUB2_618150', 'Producto Test Subtotal 2', 'Test', 1000, 1000, 10, 2, 'unidad', 1, 0, 'TEST_TENANT_618150');
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 0, 'pendiente', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES (v_compra_id, 'TEST_PROD_SUB_618150', 'Producto Test Subtotal', 1, 1000, 1000, 'unidad', 6);

  SELECT stock*uds_empaque+uds_sueltas INTO v_pool_antes FROM inventario WHERE id='TEST_PROD_SUB_618150';

  -- T1: sueltas=0 => 6 x 120000 = 720000 (idéntico a la regla anterior qty × costo)
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_SUB_618150","nombre":"Producto Test Subtotal","qty":6,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":0}]'::jsonb)->>'total';
  SELECT subtotal::text, sueltas INTO v_st, v_sue FROM compras_items WHERE compra_id=v_compra_id;
  SELECT total::text INTO v_tot FROM compras WHERE id=v_compra_id;
  ASSERT v_st = '720000', format('S5-T1: subtotal esperado 720000, obtenido %s', v_st);
  ASSERT v_tot = '720000' AND v_ret = '720000', format('S5-T1: total esperado 720000, obtenido %s (RPC %s)', v_tot, v_ret);
  ASSERT v_sue = 0, 'S5-T1: sueltas debia quedar en 0';

  -- T2: qty=6, uds=6, sueltas=4, costo=120000 => 720000 + 4×120000/6 = 800000
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_SUB_618150","nombre":"Producto Test Subtotal","qty":6,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":4}]'::jsonb)->>'total';
  SELECT subtotal::text, sueltas INTO v_st, v_sue FROM compras_items WHERE compra_id=v_compra_id;
  SELECT total::text INTO v_tot FROM compras WHERE id=v_compra_id;
  ASSERT v_st = '800000', format('S5-T2: subtotal esperado 800000, obtenido %s', v_st);
  ASSERT v_tot = '800000' AND v_ret = '800000', format('S5-T2: total esperado 800000, obtenido %s (RPC %s)', v_tot, v_ret);
  ASSERT v_sue = 4, 'S5-T2: sueltas debia quedar en 4';

  -- T3: qty=5, uds=6, sueltas=2, costo=119946 => 599730 + 2×119946/6 = 639712
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_SUB_618150","nombre":"Producto Test Subtotal","qty":5,"costo":119946,"tipo":"unidad","uds_empaque":6,"sueltas":2}]'::jsonb)->>'total';
  SELECT subtotal::text, sueltas INTO v_st, v_sue FROM compras_items WHERE compra_id=v_compra_id;
  SELECT total::text INTO v_tot FROM compras WHERE id=v_compra_id;
  ASSERT v_st = '639712', format('S5-T3: subtotal esperado 639712, obtenido %s', v_st);
  ASSERT v_tot = '639712' AND v_ret = '639712', format('S5-T3: total esperado 639712, obtenido %s (RPC %s)', v_tot, v_ret);
  ASSERT v_sue = 2, 'S5-T3: sueltas debia quedar en 2';

  -- T4: qty=6, uds=6, sueltas=4, costo=120900 => 725400 + 4×120900/6 = 806000
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_SUB_618150","nombre":"Producto Test Subtotal","qty":6,"costo":120900,"tipo":"unidad","uds_empaque":6,"sueltas":4}]'::jsonb)->>'total';
  SELECT subtotal::text, sueltas INTO v_st, v_sue FROM compras_items WHERE compra_id=v_compra_id;
  SELECT total::text INTO v_tot FROM compras WHERE id=v_compra_id;
  ASSERT v_st = '806000', format('S5-T4: subtotal esperado 806000, obtenido %s', v_st);
  ASSERT v_tot = '806000' AND v_ret = '806000', format('S5-T4: total esperado 806000, obtenido %s (RPC %s)', v_tot, v_ret);
  ASSERT v_sue = 4, 'S5-T4: sueltas debia quedar en 4';

  -- T5: uds_empaque=1 (caso defensivo/general; el frontend actual no genera
  --     sueltas con uds_empaque=1): qty=10, costo=20000, sueltas=3 => 200000 + 3×20000/1 = 260000
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_SUB2_618150","nombre":"Producto Test Subtotal 2","qty":10,"costo":20000,"tipo":"unidad","uds_empaque":1,"sueltas":3}]'::jsonb)->>'total';
  SELECT subtotal::text, sueltas INTO v_st, v_sue FROM compras_items WHERE compra_id=v_compra_id;
  SELECT total::text INTO v_tot FROM compras WHERE id=v_compra_id;
  ASSERT v_st = '260000', format('S5-T5: subtotal esperado 260000, obtenido %s', v_st);
  ASSERT v_tot = '260000' AND v_ret = '260000', format('S5-T5: total esperado 260000, obtenido %s (RPC %s)', v_tot, v_ret);
  ASSERT v_sue = 3, 'S5-T5: sueltas debia quedar en 3';

  -- T6: sueltas = -1 => LC005 y los items previos (T5) se conservan intactos
  BEGIN
    PERFORM editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
      '[{"prod_id":"TEST_PROD_SUB_618150","nombre":"Producto Test Subtotal","qty":6,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":-1}]'::jsonb);
  EXCEPTION WHEN SQLSTATE 'LC005' THEN
    v_fallo := true;
  END;
  ASSERT v_fallo = true, 'S5-T6: se esperaba LC005 por sueltas = -1';
  ASSERT (SELECT count(*) FROM compras_items WHERE compra_id=v_compra_id) = 1
     AND (SELECT subtotal::text FROM compras_items WHERE compra_id=v_compra_id) = '260000'
     AND (SELECT total::text FROM compras WHERE id=v_compra_id) = '260000',
    'S5-T6: tras el rechazo debia conservarse el item previo (260000) y el total (260000)';

  -- T7a: clave "sueltas" AUSENTE => sueltas=0 y subtotal = qty × costo
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_SUB_618150","nombre":"Producto Test Subtotal","qty":6,"costo":120000,"tipo":"unidad","uds_empaque":6}]'::jsonb)->>'total';
  SELECT subtotal::text, sueltas INTO v_st, v_sue FROM compras_items WHERE compra_id=v_compra_id;
  ASSERT v_sue = 0, 'S5-T7a: sin la clave sueltas debia quedar en 0';
  ASSERT v_st = '720000' AND v_ret = '720000', format('S5-T7a: subtotal esperado 720000 (qty×costo), obtenido %s', v_st);

  -- T7b: "sueltas": null => tratado como 0
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_SUB_618150","nombre":"Producto Test Subtotal","qty":6,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":null}]'::jsonb)->>'total';
  SELECT subtotal::text, sueltas INTO v_st, v_sue FROM compras_items WHERE compra_id=v_compra_id;
  ASSERT v_sue = 0, 'S5-T7b: "sueltas":null debia quedar en 0';
  ASSERT v_st = '720000' AND v_ret = '720000', format('S5-T7b: subtotal esperado 720000, obtenido %s', v_st);

  -- T8: varias líneas (una con sueltas, otra sin) => total = suma de subtotales
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_SUB_618150","nombre":"Producto Test Subtotal","qty":5,"costo":119946,"tipo":"unidad","uds_empaque":6,"sueltas":2},
      {"prod_id":"TEST_PROD_SUB2_618150","nombre":"Producto Test Subtotal 2","qty":2,"costo":50000,"tipo":"unidad","uds_empaque":1,"sueltas":0}]'::jsonb)->>'total';
  SELECT total::text INTO v_tot FROM compras WHERE id=v_compra_id;
  ASSERT v_tot = '739712' AND v_ret = '739712', format('S5-T8: total esperado 739712 (639712 + 100000), obtenido %s (RPC %s)', v_tot, v_ret);
  ASSERT (SELECT SUM(subtotal) FROM compras_items WHERE compra_id=v_compra_id) = (SELECT total FROM compras WHERE id=v_compra_id),
    'S5-T8: compras.total debia ser exactamente la suma de compras_items.subtotal';

  -- La edición nunca toca inventario
  SELECT stock*uds_empaque+uds_sueltas INTO v_pool_despues FROM inventario WHERE id='TEST_PROD_SUB_618150';
  ASSERT v_pool_antes = v_pool_despues, 'S5: editar NO debe modificar inventario';

  RAISE NOTICE 'BLOQUE S5 (subtotal editar con sueltas: 720000 / 800000 / 639712 / 806000 / 260000 / LC005 / sueltas ausente=0 / total mixto 739712): PASS';
END $$;

-- BLOQUE S6 — EDICIÓN "VACÍA": una compra ya guardada por el frontend con
--             qty=6, uds=6, sueltas=4, costo=120000 y subtotal=800000 se
--             re-envía SIN CAMBIAR NADA. El subtotal y el total deben seguir
--             en 800000 (antes de HITO 3.7 el RPC los bajaba a 720000 y
--             perdía silenciosamente 80000). Se repite dos veces (idempotencia).
DO $$
DECLARE
  v_compra_id uuid := gen_random_uuid();
  v_ret text; v_st text; v_tot text; v_sue integer;
  v_items jsonb := '[{"prod_id":"TEST_PROD_VAC_618150","nombre":"Producto Test Vacia","qty":6,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":4}]'::jsonb;
BEGIN
  INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, stock_min, empaque, uds_empaque, uds_sueltas, id_licencia)
  VALUES ('TEST_PROD_VAC_618150', 'Producto Test Vacia', 'Test', 1000, 1000, 10, 2, 'unidad', 6, 1, 'TEST_TENANT_618150');
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 800000, 'pendiente', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque, sueltas)
  VALUES (v_compra_id, 'TEST_PROD_VAC_618150', 'Producto Test Vacia', 6, 120000, 800000, 'unidad', 6, 4);

  FOR i IN 1..2 LOOP
    v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal', v_items)->>'total';
    SELECT subtotal::text, sueltas INTO v_st, v_sue FROM compras_items WHERE compra_id=v_compra_id;
    SELECT total::text INTO v_tot FROM compras WHERE id=v_compra_id;
    ASSERT v_st = '800000', format('S6 (pasada %s): subtotal esperado 800000, obtenido %s', i, v_st);
    ASSERT v_tot = '800000' AND v_ret = '800000', format('S6 (pasada %s): total esperado 800000, obtenido %s (RPC %s)', i, v_tot, v_ret);
    ASSERT v_sue = 4, format('S6 (pasada %s): sueltas debia seguir en 4, obtenido %s', i, v_sue);
  END LOOP;

  RAISE NOTICE 'BLOQUE S6 (edicion vacia 6/6/4/120000: subtotal y total siguen en 800000, 2 pasadas): PASS';
END $$;

-- BLOQUE S7 — VALIDACIÓN DE CANTIDAD EN editar_compra_atomica (HITO 3.7):
--             una línea es válida si qty > 0 OR sueltas > 0. qty=0 con sueltas>0
--             es una compra de SOLO unidades sueltas (p.ej. 3 unidades de un
--             six-pack): el frontend la genera y recibir/eliminar ya la soportan.
--             Se rechaza (LC005): qty=0 sin sueltas, sueltas < 0, y qty NULL o
--             negativa (esto último igual que antes de este cambio).
--             V1 qty=0,sueltas=3 => OK             V5 qty=0,sueltas=-1 => LC005
--             V2 qty=5,sueltas=0 => OK             V6 qty=5,sueltas=-1 => LC005
--             V3 qty=5,sueltas=2 => OK             V7 qty=0,uds=6,sueltas=3,costo=120000 => 60000
--             V4 qty=0,sueltas=0 => LC005          V8 qty=-2,sueltas=3 y qty ausente => LC005
--             V9 línea solo-sueltas: edición vacía, línea mixta, recibir y eliminar coherentes.
DO $$
DECLARE
  v_compra_id  uuid := gen_random_uuid();
  v_compra2_id uuid := gen_random_uuid();
  v_rechazo boolean;
  v_st text; v_tot text; v_ret text; v_qty numeric; v_sue integer;
  v_pool0 integer; v_pool1 integer; v_pool2 integer;
BEGIN
  INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, stock_min, empaque, uds_empaque, uds_sueltas, id_licencia)
  VALUES ('TEST_PROD_Q0_618150',  'Producto Test Qty0',   'Test', 1000, 1000, 10, 2, 'unidad', 6, 1, 'TEST_TENANT_618150'),
         ('TEST_PROD_Q0B_618150', 'Producto Test Qty0 B', 'Test', 1000, 1000, 10, 2, 'unidad', 1, 0, 'TEST_TENANT_618150');
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 0, 'pendiente', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES (v_compra_id, 'TEST_PROD_Q0_618150', 'Producto Test Qty0', 1, 1000, 1000, 'unidad', 6);

  -- V2: qty=5, sueltas=0 => se acepta; subtotal = 5 x 120000
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","qty":5,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":0}]'::jsonb)->>'total';
  SELECT qty, sueltas, subtotal::text INTO v_qty, v_sue, v_st FROM compras_items WHERE compra_id = v_compra_id;
  ASSERT v_qty = 5 AND v_sue = 0 AND v_st = '600000' AND v_ret = '600000',
    format('S7-V2: qty=5,sueltas=0 debia aceptarse con subtotal 600000 (qty=%s sueltas=%s subtotal=%s total=%s)', v_qty, v_sue, v_st, v_ret);

  -- V3: qty=5, sueltas=2 => se acepta; subtotal = 5 x 120000 + 2 x 120000 / 6 = 640000
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","qty":5,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":2}]'::jsonb)->>'total';
  SELECT qty, sueltas, subtotal::text INTO v_qty, v_sue, v_st FROM compras_items WHERE compra_id = v_compra_id;
  ASSERT v_qty = 5 AND v_sue = 2 AND v_st = '640000' AND v_ret = '640000',
    format('S7-V3: qty=5,sueltas=2 debia aceptarse con subtotal 640000 (qty=%s sueltas=%s subtotal=%s total=%s)', v_qty, v_sue, v_st, v_ret);

  -- V1: qty=0, sueltas=3 (SOLO sueltas) => se acepta y se persiste tal cual;
  --     costo=90000, uds=6 => subtotal = 3 x 90000 / 6 = 45000
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","qty":0,"costo":90000,"tipo":"unidad","uds_empaque":6,"sueltas":3}]'::jsonb)->>'total';
  SELECT qty, sueltas, subtotal::text INTO v_qty, v_sue, v_st FROM compras_items WHERE compra_id = v_compra_id;
  ASSERT v_qty = 0 AND v_sue = 3 AND v_st = '45000' AND v_ret = '45000',
    format('S7-V1: qty=0,sueltas=3 debia aceptarse y persistirse con subtotal 45000 (qty=%s sueltas=%s subtotal=%s total=%s)', v_qty, v_sue, v_st, v_ret);

  -- V7: qty=0, uds=6, sueltas=3, costo=120000 => subtotal = 3 x (120000 / 6) = 60000
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","qty":0,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":3}]'::jsonb)->>'total';
  SELECT qty, sueltas, subtotal::text INTO v_qty, v_sue, v_st FROM compras_items WHERE compra_id = v_compra_id;
  SELECT total::text INTO v_tot FROM compras WHERE id = v_compra_id;
  ASSERT v_qty = 0 AND v_sue = 3 AND v_st = '60000' AND v_tot = '60000' AND v_ret = '60000',
    format('S7-V7: qty=0,sueltas=3,costo=120000,uds=6 debia dar subtotal 60000 (subtotal=%s total=%s RPC=%s)', v_st, v_tot, v_ret);

  -- V4: qty=0, sueltas=0 => LINEA VACIA, se rechaza (LC005)
  v_rechazo := false;
  BEGIN
    PERFORM editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
      '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","qty":0,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":0}]'::jsonb);
  EXCEPTION WHEN SQLSTATE 'LC005' THEN v_rechazo := true;
  END;
  ASSERT v_rechazo, 'S7-V4: qty=0,sueltas=0 debia rechazarse con LC005';

  -- V5: qty=0, sueltas=-1 => LC005
  v_rechazo := false;
  BEGIN
    PERFORM editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
      '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","qty":0,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":-1}]'::jsonb);
  EXCEPTION WHEN SQLSTATE 'LC005' THEN v_rechazo := true;
  END;
  ASSERT v_rechazo, 'S7-V5: qty=0,sueltas=-1 debia rechazarse con LC005';

  -- V6: qty=5, sueltas=-1 => LC005 (sueltas negativa se rechaza aunque qty sea valida)
  v_rechazo := false;
  BEGIN
    PERFORM editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
      '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","qty":5,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":-1}]'::jsonb);
  EXCEPTION WHEN SQLSTATE 'LC005' THEN v_rechazo := true;
  END;
  ASSERT v_rechazo, 'S7-V6: qty=5,sueltas=-1 debia rechazarse con LC005';

  -- V8a: qty=-2, sueltas=3 => LC005. La qty NEGATIVA se rechazaba antes de este
  --      cambio y sigue rechazandose aunque haya sueltas (restaria inventario).
  v_rechazo := false;
  BEGIN
    PERFORM editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
      '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","qty":-2,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":3}]'::jsonb);
  EXCEPTION WHEN SQLSTATE 'LC005' THEN v_rechazo := true;
  END;
  ASSERT v_rechazo, 'S7-V8a: qty=-2,sueltas=3 debia rechazarse con LC005 (qty negativa)';

  -- V8b: qty ausente (NULL), sueltas=3 => LC005 (como antes: qty NULL se rechaza)
  v_rechazo := false;
  BEGIN
    PERFORM editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
      '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":3}]'::jsonb);
  EXCEPTION WHEN SQLSTATE 'LC005' THEN v_rechazo := true;
  END;
  ASSERT v_rechazo, 'S7-V8b: qty ausente debia rechazarse con LC005';

  -- Tras TODOS los rechazos, la linea del V7 sigue intacta (rollback completo)
  SELECT qty, sueltas, subtotal::text INTO v_qty, v_sue, v_st FROM compras_items WHERE compra_id = v_compra_id;
  SELECT total::text INTO v_tot FROM compras WHERE id = v_compra_id;
  ASSERT (SELECT count(*) FROM compras_items WHERE compra_id = v_compra_id) = 1
     AND v_qty = 0 AND v_sue = 3 AND v_st = '60000' AND v_tot = '60000',
    format('S7: tras los rechazos debia conservarse la linea qty=0,sueltas=3,subtotal=60000 (qty=%s sueltas=%s subtotal=%s total=%s)', v_qty, v_sue, v_st, v_tot);

  -- V9a: EDICION VACIA de una linea solo-sueltas (dos pasadas): subtotal y total no cambian
  FOR i IN 1..2 LOOP
    v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
      '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","qty":0,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":3}]'::jsonb)->>'total';
    SELECT qty, sueltas, subtotal::text INTO v_qty, v_sue, v_st FROM compras_items WHERE compra_id = v_compra_id;
    ASSERT v_qty = 0 AND v_sue = 3 AND v_st = '60000' AND v_ret = '60000',
      format('S7-V9a (pasada %s): la edicion vacia debia dejar subtotal 60000 (qty=%s sueltas=%s subtotal=%s total=%s)', i, v_qty, v_sue, v_st, v_ret);
  END LOOP;

  -- V9b: linea mixta: solo-sueltas (60000) + linea normal 2 x 50000 (100000) => total 160000
  v_ret := editar_compra_atomica(v_compra_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","qty":0,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":3},
      {"prod_id":"TEST_PROD_Q0B_618150","nombre":"Producto Test Qty0 B","qty":2,"costo":50000,"tipo":"unidad","uds_empaque":1,"sueltas":0}]'::jsonb)->>'total';
  ASSERT v_ret = '160000' AND (SELECT total::text FROM compras WHERE id = v_compra_id) = '160000'
     AND (SELECT SUM(subtotal) FROM compras_items WHERE compra_id = v_compra_id) = 160000,
    format('S7-V9b: total esperado 160000 (60000 + 100000), obtenido %s', v_ret);

  -- V9c: coherencia con recibir/eliminar: compra de SOLO 3 sueltas, creada por editar,
  --      suma +3 unidades al recibirse y las resta al eliminarse.
  INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
  VALUES (v_compra2_id, 'TEST_TENANT_618150', 'Proveedor Test', CURRENT_DATE, '', 0, 'pendiente', 'principal');
  INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
  VALUES (v_compra2_id, 'TEST_PROD_Q0_618150', 'Producto Test Qty0', 1, 1000, 1000, 'unidad', 6);
  PERFORM editar_compra_atomica(v_compra2_id, 'TEST_TENANT_618150', 'completa', NULL, CURRENT_DATE, '', 'principal',
    '[{"prod_id":"TEST_PROD_Q0_618150","nombre":"Producto Test Qty0","qty":0,"costo":120000,"tipo":"unidad","uds_empaque":6,"sueltas":3}]'::jsonb);
  SELECT stock*uds_empaque+uds_sueltas INTO v_pool0 FROM inventario WHERE id = 'TEST_PROD_Q0_618150';   -- 10 x 6 + 1 = 61
  PERFORM recibir_compra_atomica(v_compra2_id, 'TEST_TENANT_618150');
  SELECT stock*uds_empaque+uds_sueltas INTO v_pool1 FROM inventario WHERE id = 'TEST_PROD_Q0_618150';
  ASSERT v_pool1 = v_pool0 + 3, format('S7-V9c: recibir una compra de solo 3 sueltas debia sumar +3 (antes %s, despues %s)', v_pool0, v_pool1);
  PERFORM eliminar_compra_atomica(v_compra2_id, 'TEST_TENANT_618150');
  SELECT stock*uds_empaque+uds_sueltas INTO v_pool2 FROM inventario WHERE id = 'TEST_PROD_Q0_618150';
  ASSERT v_pool2 = v_pool0, format('S7-V9c: eliminar debia devolver el inventario exacto (antes %s, despues %s)', v_pool0, v_pool2);

  RAISE NOTICE 'BLOQUE S7 (qty=0 con sueltas: acepta 0/3, 5/0, 5/2, subtotal 60000; rechaza 0/0, 0/-1, 5/-1, qty<0, qty NULL; edicion vacia, linea mixta y recibir/eliminar coherentes): PASS';
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
    RAISE NOTICE '=== TODOS LOS BLOQUES DE PRUEBA (1-10 y S1-S7) COMPLETADOS ===';
END $$;

ROLLBACK;
-- El ROLLBACK final deshace absolutamente todo lo anterior: fixtures,
-- compras de prueba, cambios de inventario de prueba. Nada de este archivo
-- persiste, incluso si se ejecuta completo y todas las pruebas pasan.
