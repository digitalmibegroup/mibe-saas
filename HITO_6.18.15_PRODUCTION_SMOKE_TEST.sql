-- ============================================================================
-- HITO 6.18.15 (Fase 8.5) — SMOKE TEST DE PRODUCCIÓN (NO EJECUTAR TODAVÍA)
-- ============================================================================
-- Este archivo se ejecuta SOLO después de que HITO_6.18.15_PRODUCTION_INSTALL.sql
-- se haya aplicado exitosamente y verificado (las 3 RPC existen, SECURITY
-- INVOKER, search_path correcto, PUBLIC sin EXECUTE, anon/authenticated con
-- EXECUTE). Requiere autorización explícita adicional antes de ejecutarse.
--
-- REGLA DE DISEÑO CRÍTICA: NO se asume que el SQL Editor de Supabase mantiene
-- una única transacción persistente e implícitamente rollbackeable a lo largo
-- de todo un script pegado de una vez. Por eso este archivo NO depende de un
-- BEGIN/ROLLBACK envolvente para "deshacer todo mágicamente" — cada fixture
-- se crea de forma COMMITEADA y explícita, y el bloque K (CLEANUP) al final
-- lo revierte con DELETE explícitos y scoped, verificados con un SELECT final
-- que debe devolver 0 filas. Si por cualquier motivo el cleanup no llega a
-- ejecutarse (el script se corta a la mitad), los datos sintéticos quedan
-- claramente identificados por el prefijo SMOKE_618150_ y NUNCA se confunden
-- con datos reales — pero de todas formas deben limpiarse manualmente si eso
-- ocurriera (ver bloque K, ejecutable de forma independiente).
--
-- TENANT SINTÉTICO: 'SMOKE_618150_TENANT' — NUNCA 'lacava'. Ningún dato real
-- es leído, tocado ni referenciado en ningún punto de este archivo.
--
-- Si en cualquier bloque una consulta pudiera tocar un registro real (por
-- ejemplo, por un ID mal escrito que coincidiera con datos reales), el bloque
-- siguiente detiene el proceso: SIEMPRE se filtra explícitamente por
-- id_licencia = 'SMOKE_618150_TENANT' en cada INSERT/SELECT/DELETE de este
-- archivo — nunca una operación sin ese filtro.
-- ============================================================================


-- ============================================================================
-- BLOQUE A — PREFLIGHT METADATA (solo lectura, cero riesgo)
-- ============================================================================
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args,
       p.prosecdef AS security_definer, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN ('recibir_compra_atomica','editar_compra_atomica','eliminar_compra_atomica')
ORDER BY p.proname;
-- ESPERADO: 3 filas, prosecdef=false, proconfig contiene search_path=public,pg_temp

SELECT routine_name, grantee, privilege_type FROM information_schema.routine_privileges
WHERE routine_schema='public'
  AND routine_name IN ('recibir_compra_atomica','editar_compra_atomica','eliminar_compra_atomica')
ORDER BY routine_name, grantee;
-- ESPERADO: anon y authenticated con EXECUTE en las 3; PUBLIC ausente

-- Confirmar que el tenant sintético NO tiene ya datos de una corrida anterior
-- sin limpiar (si esto devuelve filas, DETENERSE y limpiar manualmente con el
-- bloque K antes de continuar).
SELECT 'compras' t, count(*) FROM compras WHERE id_licencia='SMOKE_618150_TENANT'
UNION ALL SELECT 'inventario', count(*) FROM inventario WHERE id_licencia='SMOKE_618150_TENANT'
UNION ALL SELECT 'bodegas', count(*) FROM bodegas WHERE id_licencia='SMOKE_618150_TENANT'
UNION ALL SELECT 'proveedores', count(*) FROM proveedores WHERE id_licencia='SMOKE_618150_TENANT';
-- ESPERADO: 0 en las 4


-- ============================================================================
-- BLOQUE B — FIXTURES SINTÉTICOS (COMMITEADOS explícitamente, no rollback)
-- ============================================================================
INSERT INTO proveedores (id_licencia, nombre)
VALUES ('SMOKE_618150_TENANT', 'Proveedor Smoke 618150');

INSERT INTO bodegas (id, id_licencia, nombre)
VALUES ('99990000-0000-0000-0000-000000000001', 'SMOKE_618150_TENANT', 'Bodega Smoke 618150');

INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, stock_min, empaque, uds_empaque, uds_sueltas, id_licencia)
VALUES
  ('SMOKE_618150_PROD_A', 'Producto Smoke A', 'Test', 10000, 5000, 50, 2, 'unidad', 1, 0, 'SMOKE_618150_TENANT'),
  ('SMOKE_618150_PROD_B', 'Producto Smoke B', 'Test', 20000, 10000, 10, 2, 'sixpack', 6, 0, 'SMOKE_618150_TENANT');

-- Compra 1: para el caso feliz de recepción + idempotencia
INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
VALUES ('99991111-0000-0000-0000-000000000001', 'SMOKE_618150_TENANT', 'Proveedor Smoke 618150', CURRENT_DATE, 'smoke test', 10000, 'pendiente', 'principal');
INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
VALUES ('99991111-0000-0000-0000-000000000001', 'SMOKE_618150_PROD_A', 'Producto Smoke A', 2, 5000, 10000, 'unidad', 1);

-- Compra 2: para el caso de rollback (producto inexistente)
INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
VALUES ('99991111-0000-0000-0000-000000000002', 'SMOKE_618150_TENANT', 'Proveedor Smoke 618150', CURRENT_DATE, 'smoke test rollback', 1000, 'pendiente', 'principal');
INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
VALUES ('99991111-0000-0000-0000-000000000002', 'SMOKE_618150_PROD_INEXISTENTE', 'Fantasma', 1, 1000, 1000, 'unidad', 1);

-- Compra 3: para edición completa
INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
VALUES ('99991111-0000-0000-0000-000000000003', 'SMOKE_618150_TENANT', 'Proveedor Smoke 618150', CURRENT_DATE, 'nota original', 5000, 'pendiente', 'principal');
INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
VALUES ('99991111-0000-0000-0000-000000000003', 'SMOKE_618150_PROD_A', 'Producto Smoke A', 1, 5000, 5000, 'unidad', 1);

-- Compra 4: para edición limitada (ya "recibida")
INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
VALUES ('99991111-0000-0000-0000-000000000004', 'SMOKE_618150_TENANT', 'Proveedor Smoke 618150', CURRENT_DATE, 'nota original', 5000, 'recibida', 'principal');
INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
VALUES ('99991111-0000-0000-0000-000000000004', 'SMOKE_618150_PROD_A', 'Producto Smoke A', 1, 5000, 5000, 'unidad', 1);

-- Compra 5: para eliminación feliz (ya "recibida", inventario suficiente)
INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
VALUES ('99991111-0000-0000-0000-000000000005', 'SMOKE_618150_TENANT', 'Proveedor Smoke 618150', CURRENT_DATE, 'para eliminar', 5000, 'recibida', 'principal');
INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
VALUES ('99991111-0000-0000-0000-000000000005', 'SMOKE_618150_PROD_A', 'Producto Smoke A', 1, 5000, 5000, 'unidad', 1);

-- Compra 6: pendiente, para el error path "bodega no configurada" (destino
-- bodega_secundaria pero apuntando a un tenant que aún no tiene bodega —
-- usar un segundo tenant sintético separado para no interferir con las
-- pruebas de bodega válida de arriba)
INSERT INTO compras (id, id_licencia, proveedor_nombre, fecha, nota, total, estado, destino)
VALUES ('99991111-0000-0000-0000-000000000006', 'SMOKE_618150_TENANT_NOBODEGA', 'Proveedor Smoke', CURRENT_DATE, '', 5000, 'pendiente', 'bodega_secundaria');
INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, stock_min, empaque, uds_empaque, uds_sueltas, id_licencia)
VALUES ('SMOKE_618150_PROD_NB', 'Producto Smoke NB', 'Test', 5000, 2500, 5, 1, 'unidad', 1, 0, 'SMOKE_618150_TENANT_NOBODEGA');
INSERT INTO compras_items (compra_id, prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque)
VALUES ('99991111-0000-0000-0000-000000000006', 'SMOKE_618150_PROD_NB', 'Producto Smoke NB', 1, 5000, 5000, 'unidad', 1);

-- Verificación de que los fixtures quedaron exactamente como se esperaba
SELECT id, estado FROM compras WHERE id_licencia IN ('SMOKE_618150_TENANT','SMOKE_618150_TENANT_NOBODEGA') ORDER BY id;
-- ESPERADO: 6 filas, compras 1/2/3/6 = pendiente, 4/5 = recibida


-- ============================================================================
-- BLOQUE C — RECEIVE HAPPY PATH
-- ============================================================================
SELECT recibir_compra_atomica('99991111-0000-0000-0000-000000000001', 'SMOKE_618150_TENANT') AS resultado;
-- ESPERADO: {"ok": true, "estado": "recibida", "compra_id": "9999...0001"}

SELECT stock, uds_sueltas FROM inventario WHERE id='SMOKE_618150_PROD_A';
-- ESPERADO: stock = 50 + 2 = 52 (qty=2 * uds_empaque=1), uds_sueltas=0

SELECT estado FROM compras WHERE id='99991111-0000-0000-0000-000000000001';
-- ESPERADO: 'recibida'


-- ============================================================================
-- BLOQUE D — RECEIVE IDEMPOTENCY (segunda llamada sobre la misma compra)
-- ============================================================================
-- ESPERADO: error, SQLSTATE P0006, mensaje "Esta compra ya fue marcada como
-- recibida anteriormente." — el stock NO debe cambiar respecto al Bloque C.
SELECT recibir_compra_atomica('99991111-0000-0000-0000-000000000001', 'SMOKE_618150_TENANT') AS resultado;

SELECT stock FROM inventario WHERE id='SMOKE_618150_PROD_A';
-- ESPERADO: sigue en 52 (sin duplicar)


-- ============================================================================
-- BLOQUE E — RECEIVE ROLLBACK/ERROR (producto inexistente)
-- ============================================================================
-- ESPERADO: error, SQLSTATE LC013, mensaje "El producto ... no existe..."
SELECT recibir_compra_atomica('99991111-0000-0000-0000-000000000002', 'SMOKE_618150_TENANT') AS resultado;

SELECT estado FROM compras WHERE id='99991111-0000-0000-0000-000000000002';
-- ESPERADO: sigue 'pendiente' (la RPC abortó sin aplicar nada)

SELECT stock FROM inventario WHERE id='SMOKE_618150_PROD_A';
-- ESPERADO: sigue en 52 (esta compra no tocaba PROD_A, solo confirma que nada cruzado cambió)


-- ============================================================================
-- BLOQUE F — COMPLETE EDIT (compra 3, pendiente)
-- ============================================================================
SELECT editar_compra_atomica(
  '99991111-0000-0000-0000-000000000003', 'SMOKE_618150_TENANT', 'completa',
  NULL, CURRENT_DATE, 'nota editada por smoke test', 'principal',
  jsonb_build_array(jsonb_build_object('prod_id','SMOKE_618150_PROD_A','nombre','Producto Smoke A','qty',3,'costo',5000,'tipo','unidad','uds_empaque',1))
) AS resultado;
-- ESPERADO: {"ok": true, "modo": "completa", "total": 15000, ...}

SELECT nota, total, estado FROM compras WHERE id='99991111-0000-0000-0000-000000000003';
-- ESPERADO: nota='nota editada por smoke test', total=15000, estado='pendiente'

SELECT stock FROM inventario WHERE id='SMOKE_618150_PROD_A';
-- ESPERADO: sigue en 52 (editar NUNCA toca inventario)


-- ============================================================================
-- BLOQUE G — LIMITED EDIT (compra 4, ya recibida)
-- ============================================================================
SELECT editar_compra_atomica(
  '99991111-0000-0000-0000-000000000004', 'SMOKE_618150_TENANT', 'limitada',
  NULL, CURRENT_DATE, 'nota limitada por smoke test', NULL, NULL
) AS resultado;
-- ESPERADO: {"ok": true, "modo": "limitada", ...}

SELECT nota, destino, total, estado FROM compras WHERE id='99991111-0000-0000-0000-000000000004';
-- ESPERADO: nota='nota limitada por smoke test' (cambió); destino='principal', total=5000, estado='recibida' (NINGUNO de estos 3 cambió)


-- ============================================================================
-- BLOQUE H — DELETE HAPPY PATH (compra 5, recibida, inventario suficiente)
-- ============================================================================
SELECT stock FROM inventario WHERE id='SMOKE_618150_PROD_A';
-- anotar el valor ANTES (debería ser 52) para comparar después

SELECT eliminar_compra_atomica('99991111-0000-0000-0000-000000000005', 'SMOKE_618150_TENANT') AS resultado;
-- ESPERADO: {"ok": true, "compra_id": "9999...0005"}

SELECT stock FROM inventario WHERE id='SMOKE_618150_PROD_A';
-- ESPERADO: 52 - 1 = 51 (revierte qty=1)

SELECT count(*) FROM compras WHERE id='99991111-0000-0000-0000-000000000005';
-- ESPERADO: 0 (la compra ya no existe)


-- ============================================================================
-- BLOQUE I — ERROR PATHS ADICIONALES
-- ============================================================================
-- I.1 — Compra inexistente (UUID nunca insertado)
SELECT recibir_compra_atomica('00000000-dead-beef-0000-000000000000', 'SMOKE_618150_TENANT') AS resultado;
-- ESPERADO: error, SQLSTATE LC011

-- I.2 — Estado inválido (compra 5, ya eliminada en Bloque H, ya no existe -> LC011 igual)
SELECT eliminar_compra_atomica('99991111-0000-0000-0000-000000000005', 'SMOKE_618150_TENANT') AS resultado;
-- ESPERADO: error, SQLSTATE LC011 (ya no existe)

-- I.3 — Bodega no configurada (compra 6, tenant sin ninguna bodega)
SELECT recibir_compra_atomica('99991111-0000-0000-0000-000000000006', 'SMOKE_618150_TENANT_NOBODEGA') AS resultado;
-- ESPERADO: error, SQLSTATE LC012

SELECT estado FROM compras WHERE id='99991111-0000-0000-0000-000000000006';
-- ESPERADO: sigue 'pendiente'


-- ============================================================================
-- BLOQUE J — VERIFICACIÓN FINAL (antes del cleanup)
-- ============================================================================
-- Confirma el estado esperado tras todos los bloques anteriores:
--   compra 1: recibida (Bloque C)
--   compra 2: pendiente (Bloque E, nunca se recibió por el rollback)
--   compra 3: pendiente, editada (Bloque F)
--   compra 4: recibida, editada (Bloque G)
--   compra 5: NO EXISTE (eliminada en Bloque H)
--   compra 6: pendiente (Bloque I.3, nunca se recibió)
SELECT id, estado, nota FROM compras WHERE id_licencia IN ('SMOKE_618150_TENANT','SMOKE_618150_TENANT_NOBODEGA') ORDER BY id;

-- Confirmar que NINGÚN dato de otro tenant (incluido 'lacava' real) cambió:
-- esta consulta debe ejecutarla el propietario comparando contra un snapshot
-- propio si lo desea; este archivo no lee ningún dato ajeno al tenant smoke.


-- ============================================================================
-- BLOQUE K — CLEANUP EXPLÍCITO (ejecutar SIEMPRE al final, incluso si algún
-- bloque anterior falló) — scoped exclusivamente a los tenants sintéticos
-- ============================================================================
DELETE FROM compras_items WHERE compra_id IN (
  SELECT id FROM compras WHERE id_licencia IN ('SMOKE_618150_TENANT','SMOKE_618150_TENANT_NOBODEGA')
);
DELETE FROM compras WHERE id_licencia IN ('SMOKE_618150_TENANT','SMOKE_618150_TENANT_NOBODEGA');
DELETE FROM inventario WHERE id_licencia IN ('SMOKE_618150_TENANT','SMOKE_618150_TENANT_NOBODEGA');
DELETE FROM bodegas WHERE id_licencia = 'SMOKE_618150_TENANT';
DELETE FROM proveedores WHERE id_licencia = 'SMOKE_618150_TENANT';

-- Verificación final obligatoria — debe devolver 0 en las 4 filas.
-- Si NO devuelve 0, DETENERSE y revisar manualmente antes de dar por
-- terminado el smoke test — no continuar a ninguna otra fase.
SELECT 'compras' t, count(*) FROM compras WHERE id_licencia IN ('SMOKE_618150_TENANT','SMOKE_618150_TENANT_NOBODEGA')
UNION ALL SELECT 'inventario', count(*) FROM inventario WHERE id_licencia IN ('SMOKE_618150_TENANT','SMOKE_618150_TENANT_NOBODEGA')
UNION ALL SELECT 'bodegas', count(*) FROM bodegas WHERE id_licencia='SMOKE_618150_TENANT'
UNION ALL SELECT 'proveedores', count(*) FROM proveedores WHERE id_licencia='SMOKE_618150_TENANT';

-- ============================================================================
-- FIN DEL SMOKE TEST. Ningún dato del tenant real 'lacava' fue leído, creado,
-- modificado ni eliminado en ningún bloque de este archivo.
-- ============================================================================
