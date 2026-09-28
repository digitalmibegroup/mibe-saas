-- ============================================================================
-- BLOQUE 2.5-B — ESQUEMA DE PRUEBA (SOLO STAGING LOCAL "lacava_staging")
-- ============================================================================
-- ⚠ NO EJECUTAR EN PRODUCCIÓN. Producción ya tiene estas tablas con datos reales.
--
-- Réplica mínima de ventas / cartera / cartera_abonos para probar la RPC
-- registrar_abono_cartera_atomico. Columnas y tipos confirmados contra
-- producción el 24-sep-2026 SOLO con lecturas GET (el error de PostgreSQL al
-- filtrar cada columna con un valor inválido revela su tipo):
--   uuid: ventas.id, cartera.id/venta_id/cliente_id, cartera_abonos.id/cartera_id/venta_id
--   numeric: totales, abonos, saldos, montos · integer: numero_venta, puntos_ganados
--   timestamptz: fechas · texto: id_cliente/id_licencia, estados, medios de pago.
-- Relaciones confirmadas en producción el 24-sep-2026 (BLOQUE 2.5-B.1) con GET
-- de "embedding" de PostgREST, que solo funciona si existe una FK real:
--   cartera.venta_id -> ventas.id            EXISTE (y es 1:1: venta_id es UNIQUE)
--   cartera_abonos.cartera_id -> cartera.id  EXISTE
--   cartera_abonos.venta_id -> ventas.id     NO EXISTE (BLOQUE 2.5-B.2: quitada aquí)
-- NO confirmados (anon no puede leer el catálogo de producción): nombres de las
-- constraints, CHECK, NOT NULL, defaults, triggers, RLS y permisos.
-- Los permisos imitan el uso real del frontend: anon/authenticated escriben
-- directamente estas tablas por REST (sin RLS observada).
-- ============================================================================

CREATE TABLE IF NOT EXISTS ventas (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at                timestamptz NOT NULL DEFAULT now(),
  id_cliente                text NOT NULL,
  numero_venta              integer,
  cliente_nombre            text,
  cliente_whatsapp          text,
  subtotal                  numeric DEFAULT 0,
  descuento                 numeric DEFAULT 0,
  total                     numeric NOT NULL DEFAULT 0,
  metodo_pago               text,
  estado                    text,
  notas                     text,
  puntos_ganados            integer DEFAULT 0,
  domicilio                 numeric DEFAULT 0,
  direccion_entrega         text,
  detalle_entrega           text,
  es_promocion              boolean DEFAULT false,
  abono                     numeric DEFAULT 0,
  saldo_pendiente           numeric DEFAULT 0,
  fecha_vencimiento_cartera timestamptz,
  cotizacion_id             uuid
);

CREATE TABLE IF NOT EXISTS cartera (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_licencia       text NOT NULL,
  venta_id          uuid NOT NULL REFERENCES ventas(id) CONSTRAINT cartera_venta_id_key UNIQUE,
  cliente_id        uuid,
  numero_venta      integer,
  cliente_nombre    text,
  cliente_whatsapp  text,
  total             numeric NOT NULL,
  saldo_pendiente   numeric NOT NULL,
  fecha_vencimiento timestamptz,
  fecha_creacion    timestamptz NOT NULL DEFAULT now(),
  estado_cartera    text NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cartera_abonos (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  id_licencia    text NOT NULL,
  cartera_id     uuid NOT NULL REFERENCES cartera(id),
  venta_id       uuid NOT NULL,              -- sin FK: producción no la tiene
  monto          numeric NOT NULL,
  fecha          timestamptz NOT NULL,
  registrado_por text NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  medio_pago     text
);

CREATE INDEX IF NOT EXISTS idx_cartera_abonos_cartera ON cartera_abonos(cartera_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON ventas, cartera, cartera_abonos TO anon, authenticated;
