-- ============================================================================
-- HITO 6.18.15 (Fase 6) — DDL reproducible del esquema Sandbox para 6.18.15
-- ============================================================================
-- ⚠ NO EJECUTADO EN ESTA FASE. Este archivo es un ENTREGABLE de diseño,
-- redactado y auditado estáticamente, pero NUNCA ejecutado contra ningún
-- Postgres real desde aquí (no se creó proyecto Sandbox, no se usó ninguna
-- credencial, no se tocó producción).
--
-- ⚠ REGLA ABSOLUTA: este archivo debe aplicarse ÚNICAMENTE contra un
-- proyecto Supabase SANDBOX vacío, recién creado, NUNCA contra el proyecto
-- de producción (project ref que empieza con "egjlrcokerffuoqwbxlh" — si
-- quien vaya a ejecutar esto ve ese ref en la esquina superior del SQL
-- Editor, o la etiqueta "PRODUCTION", debe detenerse).
--
-- ORIGEN: cada tipo/columna/constraint de este archivo proviene de la
-- auditoría READ-ONLY real ejecutada en 6.18.15 Fase 5 (12 consultas de
-- catálogo corridas por el propietario del proyecto directamente en el SQL
-- Editor de producción, resultados pegados y verificados en esta
-- conversación). Nada aquí es inventado — donde la evidencia de Fase 5 fue
-- incompleta, se documenta explícitamente como BLOCKER en vez de adivinar
-- (ver secciones marcadas más abajo).
--
-- ALCANCE: únicamente estructura (tablas, columnas, PK, FK, unique, RLS,
-- policies). CERO datos — ningún INSERT en este archivo. Los fixtures
-- sintéticos (TEST_TENANT_618150, etc.) son una fase separada posterior.
--
-- IDEMPOTENCIA: se usa CREATE TABLE simple (SIN "IF NOT EXISTS") a propósito
-- — este DDL está pensado para un Sandbox recién creado y vacío. Si se
-- corriera una segunda vez sobre el mismo Sandbox ya poblado, debe FALLAR
-- ruidosamente (tablas ya existen) en vez de continuar en silencio ocultando
-- una posible diferencia de esquema entre ejecuciones. La única excepción es
-- la extensión (paso 1), donde "IF NOT EXISTS" es la práctica estándar de
-- Postgres/Supabase y no oculta ninguna diferencia estructural.
-- ============================================================================


-- ============================================================================
-- 1) EXTENSIÓN
-- ============================================================================
-- Confirmado en Fase 5 (consulta a pg_extension): pgcrypto 1.3 está instalada
-- en producción y provee gen_random_uuid(), usado como default de PK en 6 de
-- las 8 tablas y en los fixtures de HITO_6.18.15_RPC_TESTS.sql.
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ============================================================================
-- 2) TABLAS (solo columnas — sin PK/FK inline, se agregan en pasos separados
--    más abajo, respetando el orden pedido: tablas sin FK primero, luego las
--    dependientes)
-- ============================================================================

-- ---- 2.1) Tablas sin FK saliente ----

-- inventario — todas las columnas y tipos confirmados en Fase 5 (consulta 2,
-- resultado completo pegado por el propietario). id es TEXT (formato real
-- "prod_<timestamp>"), NUNCA uuid — punto crítico ya verificado en Fase 2 y
-- reconfirmado aquí contra el esquema real.
CREATE TABLE inventario (
  id            text            NOT NULL,
  nombre        text            NOT NULL,
  categoria     text,
  precio_venta  numeric         DEFAULT 0,
  precio_costo  numeric         DEFAULT 0,
  stock         integer         DEFAULT 0,
  stock_min     integer         DEFAULT 2,
  empaque       text            DEFAULT 'unidad',
  uds_empaque   integer         DEFAULT 1,
  uds_sueltas   integer         DEFAULT 0,
  id_licencia   text            DEFAULT 'lacava',
  created_at    timestamptz     DEFAULT now(),
  imagen        text
);
-- NOTA (hallazgo ya reportado en Fase 5, reproducido tal cual, NO endurecido
-- aquí): id_licencia es NULLABLE con default 'lacava' en producción real.
-- Se reproduce exactamente así por regla explícita de esta fase ("no
-- endurecer nulabilidad respecto a producción").

-- bodegas
CREATE TABLE bodegas (
  id          uuid          NOT NULL DEFAULT gen_random_uuid(),
  id_licencia text          NOT NULL,
  nombre      text          NOT NULL,
  created_at  timestamptz   NOT NULL DEFAULT now(),
  updated_at  timestamptz   NOT NULL DEFAULT now()
);

-- proveedores
CREATE TABLE proveedores (
  id          uuid          NOT NULL DEFAULT gen_random_uuid(),
  id_licencia text          NOT NULL,
  nombre      text          NOT NULL,
  whatsapp    text,
  productos   text,
  notas       text,
  created_at  timestamptz   DEFAULT now()
);

-- ---- 2.2) Tablas dependientes (requieren que las de 2.1 ya existan para sus FK) ----

-- compras (FK a proveedores se agrega en el paso 4)
CREATE TABLE compras (
  id                uuid          NOT NULL DEFAULT gen_random_uuid(),
  id_licencia       text          NOT NULL,
  proveedor_id      uuid,
  proveedor_nombre  text,
  fecha             date          NOT NULL,
  nota              text,
  total             numeric       DEFAULT 0,
  estado            text          DEFAULT 'pendiente',
  destino           text          NOT NULL,
  created_at        timestamptz   NOT NULL DEFAULT now()
);

-- compras_items (FK a compras se agrega en el paso 4)
CREATE TABLE compras_items (
  id           uuid          NOT NULL DEFAULT gen_random_uuid(),
  compra_id    uuid,
  prod_id      text          NOT NULL,
  nombre       text          NOT NULL,
  qty          integer       NOT NULL,
  costo        numeric       NOT NULL,
  subtotal     numeric       NOT NULL,
  tipo         text          DEFAULT 'empaque',
  uds_empaque  integer       DEFAULT 1
);
-- NOTA (hallazgo Fase 5, reproducido tal cual): compra_id es NULLABLE en
-- producción real (sin NOT NULL) — no se endurece aquí. Las 3 RPC de 6.18.15
-- siempre insertan con compra_id poblado, así que esto no las afecta, pero
-- el Sandbox reproduce fielmente que el esquema real no lo obliga.

-- inventario_bodega (FK a bodegas e inventario se agregan en el paso 4)
CREATE TABLE inventario_bodega (
  id            uuid          NOT NULL DEFAULT gen_random_uuid(),
  id_licencia   text          NOT NULL,
  id_bodega     uuid          NOT NULL,
  prod_id       text          NOT NULL,
  stock         integer       NOT NULL DEFAULT 0,
  uds_sueltas   integer       NOT NULL DEFAULT 0,
  precio_costo  numeric,
  created_at    timestamptz   NOT NULL DEFAULT now(),
  updated_at    timestamptz   NOT NULL DEFAULT now()
);

-- producto_presentaciones (FK a inventario se agrega en el paso 4)
-- ⚠ BLOCKER PARCIAL — ver informe de Fase 6, sección "Hallazgos": la columna
-- real "tipo_presentacion" (existe en producción, tipo base "text" visto
-- parcialmente en la captura de Fase 5) NO se incluye aquí porque su
-- nullable/default exactos quedaron cortados en la captura y no fueron
-- confirmados por information_schema — no se inventa. Esta tabla NO es
-- usada por ninguna de las 3 RPC de 6.18.15 ni por HITO_6.18.15_RPC_TESTS.sql,
-- así que esta omisión NO bloquea el objetivo de este Sandbox (probar las 3
-- RPC de compras/inventario). Si en el futuro se necesita probar
-- producto_presentaciones específicamente, confirmar antes con:
--   select column_name, data_type, is_nullable, column_default
--   from information_schema.columns
--   where table_schema='public' and table_name='producto_presentaciones'
--     and column_name='tipo_presentacion';
CREATE TABLE producto_presentaciones (
  id                      uuid          NOT NULL DEFAULT gen_random_uuid(),
  tenant_id               uuid          NOT NULL,
  id_licencia             text          NOT NULL,
  id_producto             text          NOT NULL,
  nombre_presentacion     text,
  uds_empaque             numeric       NOT NULL DEFAULT 1,
  es_predeterminada       boolean       NOT NULL DEFAULT false,
  activo                  boolean       NOT NULL DEFAULT true,
  costo_vigente           numeric,
  codigo_barras           text,
  sku                     text,
  orden_visualizacion     integer       NOT NULL DEFAULT 0,
  origen_costo            text,
  observaciones           text,
  usuario_creacion        text,
  usuario_actualizacion   text,
  fecha_creacion          timestamptz   NOT NULL DEFAULT now(),
  fecha_actualizacion     timestamptz   NOT NULL DEFAULT now()
);

-- traslados_inventario (FK a inventario se agrega en el paso 4)
CREATE TABLE traslados_inventario (
  id                      uuid          NOT NULL DEFAULT gen_random_uuid(),
  id_licencia             text          NOT NULL,
  prod_id                 text          NOT NULL,
  origen                  text          NOT NULL,
  destino                 text          NOT NULL,
  uds_empaque_snapshot    integer       NOT NULL,
  empaques_trasladados    integer       NOT NULL DEFAULT 0,
  sueltas_trasladadas     integer       NOT NULL DEFAULT 0,
  unidades_totales        integer       NOT NULL,
  estado                  text          NOT NULL DEFAULT 'completado',
  usuario                 text,
  nota                    text,
  created_at              timestamptz   NOT NULL DEFAULT now()
);
-- NOTA: esta tabla no es usada por ninguna de las 3 RPC de 6.18.15 ni por sus
-- tests (se crea solo porque forma parte de las 8 tablas pedidas en la
-- sección 1 del prompt de esta fase, para fidelidad estructural completa).
-- fn_trasladar_inventario (la función que la escribe en producción) NO se
-- incluye en este archivo, por instrucción explícita de esta fase.


-- ============================================================================
-- 3) PRIMARY KEYS — nombres idénticos a los confirmados en Fase 5
--    (information_schema.table_constraints / key_column_usage)
-- ============================================================================
ALTER TABLE inventario                ADD CONSTRAINT inventario_pkey                PRIMARY KEY (id);
ALTER TABLE bodegas                   ADD CONSTRAINT bodegas_pkey                   PRIMARY KEY (id);
ALTER TABLE proveedores               ADD CONSTRAINT proveedores_pkey               PRIMARY KEY (id);
ALTER TABLE compras                   ADD CONSTRAINT compras_pkey                   PRIMARY KEY (id);
ALTER TABLE compras_items             ADD CONSTRAINT compras_items_pkey             PRIMARY KEY (id);
ALTER TABLE inventario_bodega         ADD CONSTRAINT inventario_bodega_pkey         PRIMARY KEY (id);
ALTER TABLE producto_presentaciones   ADD CONSTRAINT producto_presentaciones_pkey   PRIMARY KEY (id);
ALTER TABLE traslados_inventario      ADD CONSTRAINT traslados_inventario_pkey      PRIMARY KEY (id);


-- ============================================================================
-- 4) FOREIGN KEYS — nombres y columnas idénticos a los confirmados en Fase 5
--    (information_schema.table_constraints / key_column_usage /
--    constraint_column_usage). Se usa el comportamiento por defecto de
--    PostgreSQL (sin ON DELETE / ON UPDATE explícito) porque Fase 5 NO
--    consultó referential_constraints.update_rule/delete_rule — el
--    comportamiento real de producción en ese aspecto queda NO VERIFICADO;
--    no se inventa ON DELETE CASCADE ni ninguna otra variante. Esto es una
--    limitación documentada, no un olvido.
-- ============================================================================
ALTER TABLE compras
  ADD CONSTRAINT compras_proveedor_id_fkey
  FOREIGN KEY (proveedor_id) REFERENCES proveedores(id);

ALTER TABLE compras_items
  ADD CONSTRAINT compras_items_compra_id_fkey
  FOREIGN KEY (compra_id) REFERENCES compras(id);

ALTER TABLE inventario_bodega
  ADD CONSTRAINT inventario_bodega_id_bodega_fkey
  FOREIGN KEY (id_bodega) REFERENCES bodegas(id);

ALTER TABLE inventario_bodega
  ADD CONSTRAINT inventario_bodega_prod_id_fkey
  FOREIGN KEY (prod_id) REFERENCES inventario(id);

ALTER TABLE producto_presentaciones
  ADD CONSTRAINT fk_pp_producto
  FOREIGN KEY (id_producto) REFERENCES inventario(id);

ALTER TABLE traslados_inventario
  ADD CONSTRAINT traslados_inventario_prod_id_fkey
  FOREIGN KEY (prod_id) REFERENCES inventario(id);


-- ============================================================================
-- 5) UNIQUE / ÍNDICES
-- ============================================================================
-- RESUELTO EN FASE 6.2 (antes BLOCKER en Fase 6). La versión anterior de este
-- archivo dejaba estos 2 índices sin crear porque el "indexdef" de pg_indexes
-- había quedado truncado en la captura de Fase 5, y el candidato de alta
-- confianza para inventario_bodega_unico (basado en el manejo del error 409
-- en aplicarCompraAInventarioBodega() del frontend, que solo puede probar que
-- la combinación id_licencia+id_bodega+prod_id ya existía, no que esas 3
-- columnas sean las de la constraint) era INCORRECTO — sí incluía
-- id_licencia. Fase 6.2 confirmó las columnas reales mediante una consulta
-- directa a pg_index/pg_attribute (no pg_indexes/indexdef, que es lo que se
-- había truncado antes), corriendo esto en producción:
--
--   SELECT n.nspname, c.relname AS index_name, i.indisunique, a.attname,
--          x.n AS position
--   FROM pg_index i
--   JOIN pg_class c ON c.oid = i.indexrelid
--   JOIN pg_namespace n ON n.oid = c.relnamespace
--   JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS x(attnum, n) ON true
--   JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = x.attnum
--   WHERE n.nspname='public'
--     AND c.relname IN ('inventario_bodega_unico','bodegas_una_por_licencia')
--   ORDER BY c.relname, x.n;
--
-- Resultado real (columnas exactas, en orden de posición dentro del índice):
--   bodegas_una_por_licencia  -> (id_licencia)
--   inventario_bodega_unico   -> (id_bodega, prod_id)   -- SIN id_licencia
--
-- inventario_bodega_unico NO incluye id_licencia. El candidato anterior de
-- este archivo (id_licencia, id_bodega, prod_id) queda descartado por
-- evidencia directa — no se deja ni siquiera comentado para evitar
-- confusión futura.
CREATE UNIQUE INDEX inventario_bodega_unico
  ON inventario_bodega (id_bodega, prod_id);

CREATE UNIQUE INDEX bodegas_una_por_licencia
  ON bodegas (id_licencia);

-- Compatibilidad con recibir_compra_atomica (auditada en Fase 6.2, sin
-- modificar el archivo de la RPC): su único INSERT sobre inventario_bodega
-- usa "ON CONFLICT DO NOTHING" SIN lista de columnas explícita (ver
-- HITO_6.18.15_RPC_RECIBIR_COMPRA.sql, INSERT INTO inventario_bodega ...
-- ON CONFLICT DO NOTHING) — un ON CONFLICT sin target se activa ante
-- CUALQUIER violación de unique/exclusion constraint de la tabla, así que es
-- compatible tal cual con UNIQUE(id_bodega, prod_id), sin necesitar ningún
-- cambio en la RPC.
--
-- Ningún otro índice de producción (p.ej. compras_id_licencia_estado_idx,
-- los de producto_presentaciones) es necesario para el funcionamiento,
-- constraints o concurrencia de las 3 RPC de 6.18.15 — no se clonan aquí,
-- por regla explícita de "no clonar indiscriminadamente".


-- ============================================================================
-- 6) RLS — reproduce EXACTAMENTE el estado real de producción confirmado en
--    Fase 5. NO se corrige ni se endurece aquí — ese es un hito aparte,
--    fuera de alcance de 6.18.15. El objetivo de este Sandbox es probar el
--    comportamiento ACTUAL de las RPC, tal como se comportarían hoy en
--    producción, RLS incluido.
-- ============================================================================
ALTER TABLE compras                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE compras_items           ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventario              ENABLE ROW LEVEL SECURITY;
ALTER TABLE producto_presentaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE proveedores             ENABLE ROW LEVEL SECURITY;
-- bodegas, inventario_bodega, traslados_inventario: RLS NO habilitado en
-- producción (confirmado, rls_habilitado=false para las 3) — no se activa
-- aquí tampoco, para fidelidad exacta.

-- Policies — texto/condición idénticos a los devueltos por pg_policies en
-- Fase 5 (using_expr y with_check literalmente "true" en todos los casos —
-- no son un resumen simplificado, es la condición real confirmada).
CREATE POLICY "licencia propia" ON compras
  FOR ALL TO public USING (true) WITH CHECK (true);

CREATE POLICY "licencia propia" ON compras_items
  FOR ALL TO public USING (true) WITH CHECK (true);

CREATE POLICY "anon_all_inventario" ON inventario
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY "licencia propia" ON proveedores
  FOR ALL TO public USING (true) WITH CHECK (true);

CREATE POLICY "pp_select" ON producto_presentaciones
  FOR SELECT TO public USING (true);

CREATE POLICY "pp_insert" ON producto_presentaciones
  FOR INSERT TO public WITH CHECK (true);

CREATE POLICY "pp_update" ON producto_presentaciones
  FOR UPDATE TO public USING (true) WITH CHECK (true);

CREATE POLICY "pp_delete" ON producto_presentaciones
  FOR DELETE TO public USING (true);

-- NOTA IMPORTANTE (ya documentada en el informe de Fase 5, repetida aquí
-- porque es la razón de ser de esta réplica exacta): estas policies, a
-- pesar de sus nombres ("licencia propia"), NO filtran nada por id_licencia
-- — son efectivamente "permitir todo". Se reproducen tal cual, sin
-- "arreglarlas", porque el objetivo de este Sandbox es que las 3 RPC de
-- 6.18.15 se comporten en las pruebas EXACTAMENTE como se comportarían hoy
-- en producción — incluyendo esta debilidad real y ya reportada. Corregir
-- las policies reales es, por regla explícita de esta fase, un hito
-- independiente futuro, no parte de 6.18.15.


-- ============================================================================
-- FIN DEL DDL. NO se crean aquí las 3 RPC de 6.18.15 (recibir/editar/
-- eliminar_compra_atomica) ni fn_trasladar_inventario, ni se insertan datos.
-- Orden de aplicación completo previsto (fuera de esta fase):
--   1. este archivo (schema)
--   2. HITO_6.18.15_RPC_RECIBIR_COMPRA.sql   -> verificar
--   3. HITO_6.18.15_RPC_EDITAR_COMPRA.sql    -> verificar
--   4. HITO_6.18.15_RPC_ELIMINAR_COMPRA.sql  -> verificar
--   5. HITO_6.18.15_RPC_TESTS.sql
-- ============================================================================
