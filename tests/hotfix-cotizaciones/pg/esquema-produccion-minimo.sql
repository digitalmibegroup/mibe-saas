-- Esquema MINIMO para pruebas locales de la conversion atomica de cotizaciones.
-- SOLO para un PostgreSQL temporal con datos ficticios. Nunca para staging ni produccion.
-- Columnas, tipos, nulos, valores por defecto, restricciones, indices, RLS y politicas
-- copiados de la lectura de catalogo de PRODUCCION del 16-nov-2026 (solo lectura).
-- inventario: HITO_6.18.15_SANDBOX_SCHEMA.sql (catalogo de produccion, Fase 5).
-- Como Supabase: lo que crea el administrador (aqui supa_postgres) concede ALL por defecto a anon/authenticated/service_role.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;

CREATE TABLE inventario (
  id text NOT NULL, nombre text NOT NULL, categoria text, precio_venta numeric DEFAULT 0, precio_costo numeric DEFAULT 0,
  stock integer DEFAULT 0, stock_min integer DEFAULT 2, empaque text DEFAULT 'unidad', uds_empaque integer DEFAULT 1,
  uds_sueltas integer DEFAULT 0, id_licencia text DEFAULT 'lacava', created_at timestamptz DEFAULT now(), imagen text,
  CONSTRAINT inventario_pkey PRIMARY KEY (id));

CREATE TABLE clientes_frecuentes (
  id uuid NOT NULL DEFAULT gen_random_uuid(), created_at timestamptz DEFAULT now(), id_licencia text NOT NULL DEFAULT 'lacava',
  nombre text NOT NULL, whatsapp text, puntos integer DEFAULT 0, total_compras numeric DEFAULT 0, num_pedidos integer DEFAULT 0,
  ultima_compra timestamptz, direccion text, detalle text,
  CONSTRAINT clientes_frecuentes_pkey PRIMARY KEY (id));

CREATE SEQUENCE ventas_numero_venta_seq AS integer;
CREATE TABLE ventas (
  id uuid NOT NULL DEFAULT gen_random_uuid(), created_at timestamptz DEFAULT now(), id_cliente text NOT NULL DEFAULT 'lacava',
  numero_venta integer NOT NULL DEFAULT nextval('ventas_numero_venta_seq'::regclass), cliente_nombre text, cliente_whatsapp text,
  subtotal numeric NOT NULL DEFAULT 0, descuento numeric DEFAULT 0, total numeric NOT NULL DEFAULT 0,
  metodo_pago text DEFAULT 'efectivo', estado text DEFAULT 'completada', notas text, puntos_ganados integer DEFAULT 0,
  domicilio numeric DEFAULT 0, direccion_entrega text, detalle_entrega text, es_promocion boolean DEFAULT false,
  abono numeric DEFAULT 0, saldo_pendiente numeric DEFAULT 0, fecha_vencimiento_cartera timestamptz, cotizacion_id uuid,
  CONSTRAINT ventas_pkey PRIMARY KEY (id));

CREATE TABLE cotizaciones (
  id uuid NOT NULL DEFAULT gen_random_uuid(), id_licencia text NOT NULL DEFAULT 'lacava', numero_local bigint NOT NULL,
  numero integer, cliente_nombre text NOT NULL, cliente_whatsapp text, estado text NOT NULL, items jsonb NOT NULL,
  total numeric NOT NULL, fecha_creacion timestamptz NOT NULL, fecha_vencimiento timestamptz, venta_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cotizaciones_pkey PRIMARY KEY (id),
  CONSTRAINT cotizaciones_id_licencia_numero_local_key UNIQUE (id_licencia, numero_local),
  CONSTRAINT cotizaciones_estado_check CHECK (estado = ANY (ARRAY['pendiente','aprobada','rechazada','convertida'])));
ALTER TABLE cotizaciones ADD CONSTRAINT cotizaciones_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES ventas(id);
ALTER TABLE ventas ADD CONSTRAINT ventas_cotizacion_id_fkey FOREIGN KEY (cotizacion_id) REFERENCES cotizaciones(id);
CREATE UNIQUE INDEX idx_ventas_cotizacion_unica ON public.ventas USING btree (cotizacion_id) WHERE (cotizacion_id IS NOT NULL);

CREATE TABLE detalle_ventas (
  id uuid NOT NULL DEFAULT gen_random_uuid(), created_at timestamptz DEFAULT now(), venta_id uuid, producto_nombre text NOT NULL,
  categoria text, cantidad integer NOT NULL DEFAULT 1, precio_unitario numeric NOT NULL, precio_total numeric NOT NULL,
  prod_id text, es_unidad boolean DEFAULT false, uds_empaque integer DEFAULT 1,
  CONSTRAINT detalle_ventas_pkey PRIMARY KEY (id),
  CONSTRAINT detalle_ventas_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES ventas(id) ON DELETE CASCADE);

CREATE TABLE cartera (
  id uuid NOT NULL DEFAULT gen_random_uuid(), id_licencia text NOT NULL, venta_id uuid NOT NULL, cliente_id uuid,
  numero_venta integer, cliente_nombre text, cliente_whatsapp text, total numeric NOT NULL DEFAULT 0,
  saldo_pendiente numeric NOT NULL DEFAULT 0, fecha_vencimiento timestamptz, fecha_creacion timestamptz NOT NULL DEFAULT now(),
  estado_cartera text NOT NULL DEFAULT 'activa', created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cartera_pkey PRIMARY KEY (id),
  CONSTRAINT cartera_venta_id_unique UNIQUE (venta_id),
  CONSTRAINT cartera_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES ventas(id) ON DELETE CASCADE,
  CONSTRAINT cartera_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES clientes_frecuentes(id) ON DELETE SET NULL,
  CONSTRAINT cartera_estado_chk CHECK (estado_cartera = ANY (ARRAY['activa','pagada'])),
  CONSTRAINT cartera_saldo_chk CHECK (saldo_pendiente >= 0),
  CONSTRAINT cartera_total_chk CHECK (total >= 0));
CREATE INDEX idx_cartera_venta ON public.cartera USING btree (venta_id);
CREATE OR REPLACE FUNCTION public.set_cartera_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;
CREATE TRIGGER trg_cartera_updated_at BEFORE UPDATE ON public.cartera FOR EACH ROW EXECUTE FUNCTION set_cartera_updated_at();

CREATE TABLE cartera_abonos (
  id uuid NOT NULL DEFAULT gen_random_uuid(), id_licencia text NOT NULL, cartera_id uuid NOT NULL, venta_id uuid,
  monto numeric NOT NULL, fecha timestamptz NOT NULL DEFAULT now(), registrado_por text DEFAULT 'admin',
  created_at timestamptz NOT NULL DEFAULT now(), medio_pago text,
  CONSTRAINT cartera_abonos_pkey PRIMARY KEY (id),
  CONSTRAINT cartera_abonos_cartera_fkey FOREIGN KEY (cartera_id) REFERENCES cartera(id) ON DELETE CASCADE,
  CONSTRAINT cartera_abonos_monto_chk CHECK (monto > 0));

-- Permisos y RLS como en produccion: anon/authenticated con todo sobre las tablas y politicas abiertas.
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['inventario','clientes_frecuentes','ventas','cotizaciones','detalle_ventas','cartera','cartera_abonos'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
  END LOOP; END $$;
CREATE POLICY anon_all_inventario ON inventario FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY anon_all_clientes ON clientes_frecuentes FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY anon_all_ventas ON ventas FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY anon_all_cotizaciones ON cotizaciones FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY anon_all_detalle ON detalle_ventas FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY anon_all_cartera ON cartera FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);
CREATE POLICY anon_all_cartera_abonos ON cartera_abonos FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;
