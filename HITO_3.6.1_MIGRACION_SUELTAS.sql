-- ============================================================================
-- HITO 3.6.1 — Migración: persistencia real de unidades sueltas en compras
-- ============================================================================
-- ESTADO: EJECUTADO EN PRODUCCIÓN (2026-09-21) manualmente por el propietario
-- en el SQL Editor de Supabase (proyecto mibe-saas / main / PRODUCTION).
-- Resultado verificado después desde la app (solo lectura): la columna existe,
-- compras_items conserva sus 71 filas (idénticas al conteo previo), 0 filas con
-- NULL y 0 filas con sueltas distinto de 0 (todas las históricas quedaron en 0).
-- NO volver a ejecutar: el ALTER TABLE fallaría porque la columna ya existe.
--
-- Este archivo se conserva como registro de la migración, siguiendo la
-- convención de los demás HITO_*.sql del repo.
--
-- POR QUÉ LO EJECUTÓ EL PROPIETARIO Y NO EL ASISTENTE (confirmado
-- empíricamente en esta sesión, no supuesto):
-- el entorno de trabajo (Claude Code) solo tiene acceso a la API REST de
-- Supabase (PostgREST) mediante la anon key pública embebida en el propio
-- HTML — la misma que usa la aplicación en el navegador. No hay acceso a
-- psql, a la Supabase CLI, ni a una conexión directa a Postgres con permisos
-- DDL. Se verificó explícitamente en esta sesión, sin modificar nada:
--   1) GET /rest/v1/  → 401 "Only the `service_role` API key can be used
--      for this endpoint." (el endpoint raíz de introspección exige
--      service_role, que no está disponible aquí).
--   2) POST /rest/v1/rpc/{exec_sql,execute_sql,run_sql,sql,pg_execute} → 404
--      en los 5 casos (PGRST202: función no existe) — no existe ninguna RPC
--      genérica de ejecución SQL instalada que pudiera usarse como atajo
--      (y no se creó ninguna: hacerlo sería un riesgo de seguridad serio y
--      además una RPC "CREATE FUNCTION" está explícitamente prohibida en
--      este hito).
-- Por lo tanto, el ALTER TABLE de la FASE 3 NO pudo ejecutarse desde aquí.
-- Debe aplicarlo manualmente el propietario del proyecto.
--
-- CONTEXTO (auditoría HITO 3.6, reconfirmada en HITO 3.6.1): compras_items
-- no tiene columna "sueltas". Cuando un producto con uds_empaque>1 se compra
-- con tipo='unidad' y la cantidad física no es múltiplo exacto de
-- uds_empaque, el resto (sueltas) se calcula correctamente en el frontend
-- (calcularItemCompra()) pero no tiene dónde persistirse — se pierde antes
-- de una recepción diferida (compra guardada como 'pendiente' y recibida
-- después). unidadesFisicasDeCompra() YA está preparada para leer
-- item.sueltas (item.qty*(item.uds_empaque||1)+(item.sueltas||0)) — no
-- requiere ningún cambio, solo que el dato exista al releer compras_items.
--
-- TIPOS REALES (confirmados por lectura directa de compras_items vía REST
-- en esta sesión, columnas actuales: id, compra_id, prod_id, nombre, qty,
-- costo, subtotal, tipo, uds_empaque — sin id_licencia, sin sueltas).
-- ============================================================================


-- ============================================================================
-- FASE 2 — PRE-VERIFICACIONES (ejecutar y revisar el resultado ANTES de la
-- FASE 3; si "existe_columna" ya devuelve 1 fila, NO ejecutar el ALTER TABLE
-- — la columna ya existe y el ALTER fallaría o sería redundante).
-- ============================================================================

-- 2.1) Confirmar que la columna "sueltas" NO existe todavía en compras_items.
--      Debe devolver 0 filas.
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'compras_items'
  AND column_name = 'sueltas';

-- 2.2) Confirmar la lista completa de columnas actuales de compras_items
--      (para comparar visualmente contra lo ya auditado: id, compra_id,
--      prod_id, nombre, qty, costo, subtotal, tipo, uds_empaque).
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'compras_items'
ORDER BY ordinal_position;

-- 2.3) Conteo de filas ANTES de la migración — se debe volver a contar
--      después (FASE 3, verificación final) y confirmar que coincide
--      exactamente (una migración de columna nunca debe cambiar el número
--      de filas).
SELECT count(*) AS filas_antes FROM compras_items;


-- ============================================================================
-- FASE 3 — MIGRACIÓN (el único cambio autorizado en este hito)
-- ============================================================================
-- NOT NULL + DEFAULT 0 en el mismo ALTER TABLE: Postgres aplica el DEFAULT a
-- TODAS las filas existentes en la misma operación (reescritura rápida de
-- metadato en Postgres 11+, sin necesidad de un UPDATE masivo posterior) —
-- las filas históricas quedan en sueltas=0, nunca en NULL. Esto es
-- intencional: no existe evidencia suficiente para reconstruir el valor
-- real de las filas históricas (ver HITO 3.6, sección "Impacto histórico" —
-- los 2 candidatos "Pilsen +2" y "Heineken +4" NO se corrigen aquí ni en
-- ningún otro hito sin autorización explícita separada).

ALTER TABLE compras_items
  ADD COLUMN sueltas integer NOT NULL DEFAULT 0;


-- ============================================================================
-- FASE 3 — VERIFICACIÓN POSTERIOR (ejecutar inmediatamente después del ALTER)
-- ============================================================================

-- 3.1) La columna debe existir ahora, tipo integer, NOT NULL, default 0.
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'compras_items'
  AND column_name = 'sueltas';

-- 3.2) El número de filas debe ser IDÉNTICO al de 2.3 (ninguna fila se
--      creó, borró ni movió — solo se agregó una columna).
SELECT count(*) AS filas_despues FROM compras_items;

-- 3.3) Ninguna fila debe tener NULL en sueltas (el DEFAULT + NOT NULL ya lo
--      garantiza a nivel de motor, esta consulta es solo confirmación
--      visual — debe devolver 0).
SELECT count(*) AS filas_con_sueltas_null
FROM compras_items
WHERE sueltas IS NULL;

-- 3.4) Todas las filas históricas deben tener sueltas=0 exactamente
--      (ninguna reconstrucción, ningún valor inventado).
SELECT count(*) AS filas_con_sueltas_distinto_de_cero
FROM compras_items
WHERE sueltas <> 0;
-- Resultado esperado inmediatamente después de aplicar esta migración: 0
-- (todas las filas son históricas hasta que el frontend corregido, HITO
-- 3.6.1 Fase 4, empiece a insertar valores reales).


-- ============================================================================
-- NO incluido en esta migración (fuera de alcance de este hito, por regla
-- explícita): triggers, RLS, índices, cambios de FK/constraints existentes,
-- UPDATE de datos históricos, corrección de Águila, instalación o
-- modificación de las RPC de HITO_6.18.15 (esas usarán esta columna en un
-- hito posterior de staging/RPC, no en este).
-- ============================================================================
