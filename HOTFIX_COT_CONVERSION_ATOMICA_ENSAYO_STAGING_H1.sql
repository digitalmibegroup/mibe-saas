-- ============================================================================
-- VARIANTE SOLO PARA EL ENSAYO EN EL STAGING ca10112ba2 (Compras v5 + H1). NO ES EL SQL DE PRODUCCION.
-- Generada por tests/hotfix-cotizaciones/ensayo/generar-variante-staging-h1.cjs a partir de HOTFIX_COT_CONVERSION_ATOMICA.sql
-- (que se conserva para produccion; ese SQL ya retira la membresia temporal sin tolerar fallos y lo verifica). Diferencias, todas dentro de la MISMA transaccion (un solo BEGIN y un solo COMMIT):
--   1. EXECUTE de las dos funciones SOLO para authenticated; anon no lo recibe en ningun momento (y se revoca de forma explicita).
--   2. La funcion del disparador queda sin EXECUTE para PUBLIC, anon y authenticated.
--   3. La verificacion final exige: anon no ejecuta ninguna funcion del hotfix y authenticated si ejecuta las dos RPC (el resto de
--      verificaciones, incluida la ausencia de membresia temporal, son las de produccion). Si algo falla, se deshace toda la instalacion.
-- Motivo: bajo H1 no hay acceso anonimo; el EXECUTE para anon del SQL de produccion lo reabriria. Ver PLAN_ENSAYO_HOTFIX_EN_STAGING.md.
-- ============================================================================
-- ============================================================================
-- HOTFIX COTIZACIONES — Conversion atomica de una cotizacion en venta (v2)
-- ============================================================================
-- ESTADO: probado SOLO en PostgreSQL temporal local con datos ficticios.
-- NO aplicar en staging ni en produccion sin autorizacion expresa de Michel.
--
-- Que instala:
--   1. Rol sin acceso (NOLOGIN) public.cotconv_ejecutor: dueño de las funciones y con
--      SOLO los privilegios que la conversion necesita (ver lista mas abajo).
--   2. Tabla public.cotizacion_conversiones: registro de operaciones confirmadas.
--      ANON/AUTHENTICATED NO TIENEN NINGUN PRIVILEGIO sobre ella: solo la funcion puede
--      escribirla o leerla. Es de solo-añadir (disparador): no admite UPDATE, DELETE ni
--      TRUNCATE. No tiene claves foraneas: eliminar una venta o una cotizacion por los
--      flujos normales NO borra la evidencia.
--   3. Funcion public.convertir_cotizacion_atomica(...): en UNA transaccion bloquea y
--      valida la cotizacion, valida cliente/pago/empaques/precios en la base, crea la
--      venta y su detalle, descuenta el inventario, crea cartera y abono inicial
--      (credito) y vincula la cotizacion. Cualquier error deshace TODO.
--      Un reintento con la misma clave NO confia en el registro: verifica contra el
--      estado real (venta, vinculo, cartera) y responde con los datos reales.
--   4. Funcion public.cotizacion_conversion_info(...): solo lectura, para el diagnostico.
--
-- Seguridad (revision expresa):
--   - Las dos funciones son SECURITY DEFINER y su DUEÑO es cotconv_ejecutor, NO postgres:
--     corren con los privilegios minimos del rol, no con los del administrador.
--   - Privilegios de cotconv_ejecutor (explicitos, sin DELETE ni TRUNCATE en nada):
--       SELECT  : cotizaciones, clientes_frecuentes, inventario, ventas, detalle_ventas,
--                 cartera, cartera_abonos, cotizacion_conversiones
--       INSERT  : ventas, detalle_ventas, cartera, cartera_abonos, cotizacion_conversiones
--       UPDATE  : cotizaciones(estado, venta_id, updated_at, cliente_nombre, cliente_whatsapp),
--                 inventario(stock, uds_sueltas)
--       USAGE   : secuencia ventas_numero_venta_seq y esquema public
--     Como las tablas tienen RLS, se crean politicas SOLO para este rol y por comando.
--   - search_path = public, pg_temp; todos los objetos se citan con esquema public.
--   - EXECUTE revocado a PUBLIC, anon y authenticated y concedido solo a anon y
--     authenticated sobre estas dos funciones. No se toca ninguna otra funcion.
--   - Toda lectura y escritura se filtra por p_id_licencia.
--   - LIMITE (acceso anonimo existente, fuera del alcance): p_id_licencia lo envia el
--     navegador sin autenticar, y las tablas de negocio siguen abiertas a anon con sus
--     politicas actuales. Este cambio no lo empeora ni lo resuelve (H1).
--
-- Condiciones previas (las verifica el PRECHEQUEO; si falla, no instala nada):
--   - Existen las tablas, columnas, indice y restriccion que usa la funcion.
--   - No existen el rol ni las funciones. La tabla cotizacion_conversiones puede existir
--     solo si tiene exactamente la estructura esperada (reinstalacion tras una reversion
--     que conservo el registro).
--   - Quien instala puede crear roles y poseer las tablas (en Supabase: postgres).
-- Reversion: HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql
-- Verificacion de permisos (solo lectura): HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------- PRECHEQUEO
DO $pre$
DECLARE v_falta text; v_cols text;
BEGIN
  SELECT string_agg(x.t, ', ') INTO v_falta FROM (VALUES ('cotizaciones'),('ventas'),('detalle_ventas'),('inventario'),
    ('clientes_frecuentes'),('cartera'),('cartera_abonos')) AS x(t)
  WHERE to_regclass('public.'||x.t) IS NULL;
  IF v_falta IS NOT NULL THEN RAISE EXCEPTION 'PRECHEQUEO: faltan tablas: %', v_falta; END IF;
  SELECT string_agg(t||'.'||c, ', ') INTO v_falta FROM (VALUES
    ('cotizaciones','id'),('cotizaciones','id_licencia'),('cotizaciones','estado'),('cotizaciones','items'),
    ('cotizaciones','venta_id'),('cotizaciones','updated_at'),('cotizaciones','cliente_nombre'),('cotizaciones','cliente_whatsapp'),
    ('ventas','cotizacion_id'),('ventas','direccion_entrega'),('ventas','detalle_entrega'),('ventas','abono'),
    ('ventas','saldo_pendiente'),('ventas','fecha_vencimiento_cartera'),('ventas','puntos_ganados'),('ventas','cliente_whatsapp'),
    ('detalle_ventas','es_unidad'),('detalle_ventas','uds_empaque'),('detalle_ventas','prod_id'),
    ('inventario','stock'),('inventario','uds_sueltas'),('inventario','uds_empaque'),('inventario','id_licencia'),('inventario','nombre'),
    ('clientes_frecuentes','id_licencia'),('cartera','venta_id'),('cartera','fecha_creacion'),
    ('cartera_abonos','medio_pago'),('cartera_abonos','registrado_por')) AS x(t,c)
  WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns
                     WHERE table_schema='public' AND table_name=x.t AND column_name=x.c);
  IF v_falta IS NOT NULL THEN RAISE EXCEPTION 'PRECHEQUEO: faltan columnas: %', v_falta; END IF;
  IF to_regclass('public.ventas_numero_venta_seq') IS NULL THEN RAISE EXCEPTION 'PRECHEQUEO: falta la secuencia ventas_numero_venta_seq'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND indexname='idx_ventas_cotizacion_unica') THEN
    RAISE EXCEPTION 'PRECHEQUEO: falta idx_ventas_cotizacion_unica'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='cartera_venta_id_unique') THEN
    RAISE EXCEPTION 'PRECHEQUEO: falta cartera_venta_id_unique'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='cotconv_ejecutor') THEN
    RAISE EXCEPTION 'PRECHEQUEO: el rol cotconv_ejecutor ya existe'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info')) THEN
    RAISE EXCEPTION 'PRECHEQUEO: ya existe alguna de las funciones del hotfix'; END IF;
  IF to_regclass('public.cotizacion_conversiones') IS NOT NULL THEN
    SELECT string_agg(column_name, ',' ORDER BY column_name) INTO v_cols FROM information_schema.columns
     WHERE table_schema='public' AND table_name='cotizacion_conversiones';
    IF v_cols IS DISTINCT FROM 'cotizacion_id,created_at,huella,id_licencia,op_clave,resultado,venta_id' THEN
      RAISE EXCEPTION 'PRECHEQUEO: cotizacion_conversiones existe con otra estructura (%). No se instala.', v_cols; END IF;
    RAISE NOTICE 'PRECHEQUEO: se reutiliza el registro existente de cotizacion_conversiones (reinstalacion).';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventario WHERE id_licencia IS NULL) THEN
    RAISE EXCEPTION 'PRECHEQUEO: hay productos con id_licencia NULL; revisar antes de instalar'; END IF;
END $pre$;

-- ---------------------------------------------------------------- ROL (sin login ni privilegios propios)
CREATE ROLE cotconv_ejecutor NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE cotconv_ejecutor IS 'Hotfix cotizaciones: duenio de convertir_cotizacion_atomica; privilegios minimos explicitos.';

-- ---------------------------------------------------------------- TABLA DE OPERACIONES
CREATE TABLE IF NOT EXISTS public.cotizacion_conversiones (
  op_clave       text        NOT NULL,
  id_licencia    text        NOT NULL,
  cotizacion_id  uuid        NOT NULL,   -- SIN clave foranea: la evidencia sobrevive a la venta y a la cotizacion
  venta_id       uuid        NOT NULL,   -- SIN clave foranea: la evidencia sobrevive a la eliminacion de la venta
  huella         text        NOT NULL,
  resultado      jsonb       NOT NULL,   -- copia de auditoria; los reintentos NO la devuelven: verifican el estado real
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cotizacion_conversiones_pkey PRIMARY KEY (op_clave),
  CONSTRAINT cotizacion_conversiones_clave_chk CHECK (op_clave ~ '^conv-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
);
CREATE INDEX IF NOT EXISTS idx_cotconv_cotizacion ON public.cotizacion_conversiones (id_licencia, cotizacion_id);
COMMENT ON TABLE public.cotizacion_conversiones IS 'Hotfix cotizaciones: operaciones confirmadas por convertir_cotizacion_atomica. Solo-anadir; sin acceso para anon/authenticated.';
ALTER TABLE public.cotizacion_conversiones ENABLE ROW LEVEL SECURITY;
-- Supabase concede por defecto ALL sobre tablas nuevas a anon/authenticated/service_role: se retira TODO.
REVOKE ALL ON public.cotizacion_conversiones FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.cotconv_registro_inmutable() RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $t$
BEGIN
  RAISE EXCEPTION 'cotizacion_conversiones es de solo añadir: no admite % (evidencia de operaciones).', TG_OP USING ERRCODE='CV060';
END $t$;
DROP TRIGGER IF EXISTS cotconv_inmutable_fila ON public.cotizacion_conversiones;
DROP TRIGGER IF EXISTS cotconv_inmutable_trunc ON public.cotizacion_conversiones;
CREATE TRIGGER cotconv_inmutable_fila BEFORE UPDATE OR DELETE ON public.cotizacion_conversiones
  FOR EACH ROW EXECUTE FUNCTION public.cotconv_registro_inmutable();
CREATE TRIGGER cotconv_inmutable_trunc BEFORE TRUNCATE ON public.cotizacion_conversiones
  FOR EACH STATEMENT EXECUTE FUNCTION public.cotconv_registro_inmutable();

-- ---------------------------------------------------------------- PRIVILEGIOS EXPLICITOS DEL ROL
GRANT USAGE ON SCHEMA public TO cotconv_ejecutor;
GRANT SELECT ON public.cotizaciones, public.clientes_frecuentes, public.inventario, public.ventas,
                public.detalle_ventas, public.cartera, public.cartera_abonos, public.cotizacion_conversiones TO cotconv_ejecutor;
GRANT INSERT ON public.ventas, public.detalle_ventas, public.cartera, public.cartera_abonos, public.cotizacion_conversiones TO cotconv_ejecutor;
GRANT UPDATE (estado, venta_id, updated_at, cliente_nombre, cliente_whatsapp) ON public.cotizaciones TO cotconv_ejecutor;
GRANT UPDATE (stock, uds_sueltas) ON public.inventario TO cotconv_ejecutor;
GRANT USAGE ON SEQUENCE public.ventas_numero_venta_seq TO cotconv_ejecutor;

-- Politicas RLS SOLO para este rol y por comando (las politicas de anon no cambian).
CREATE POLICY cotconv_sel_cotizaciones     ON public.cotizaciones             FOR SELECT TO cotconv_ejecutor USING (true);
CREATE POLICY cotconv_sel_clientes         ON public.clientes_frecuentes      FOR SELECT TO cotconv_ejecutor USING (true);
CREATE POLICY cotconv_sel_inventario       ON public.inventario               FOR SELECT TO cotconv_ejecutor USING (true);
CREATE POLICY cotconv_sel_ventas           ON public.ventas                   FOR SELECT TO cotconv_ejecutor USING (true);
CREATE POLICY cotconv_sel_detalle          ON public.detalle_ventas           FOR SELECT TO cotconv_ejecutor USING (true);
CREATE POLICY cotconv_sel_cartera          ON public.cartera                  FOR SELECT TO cotconv_ejecutor USING (true);
CREATE POLICY cotconv_sel_abonos           ON public.cartera_abonos           FOR SELECT TO cotconv_ejecutor USING (true);
CREATE POLICY cotconv_sel_registro         ON public.cotizacion_conversiones  FOR SELECT TO cotconv_ejecutor USING (true);
CREATE POLICY cotconv_ins_ventas           ON public.ventas                   FOR INSERT TO cotconv_ejecutor WITH CHECK (true);
CREATE POLICY cotconv_ins_detalle          ON public.detalle_ventas           FOR INSERT TO cotconv_ejecutor WITH CHECK (true);
CREATE POLICY cotconv_ins_cartera          ON public.cartera                  FOR INSERT TO cotconv_ejecutor WITH CHECK (true);
CREATE POLICY cotconv_ins_abonos           ON public.cartera_abonos           FOR INSERT TO cotconv_ejecutor WITH CHECK (true);
CREATE POLICY cotconv_ins_registro         ON public.cotizacion_conversiones  FOR INSERT TO cotconv_ejecutor WITH CHECK (true);
CREATE POLICY cotconv_upd_cotizaciones     ON public.cotizaciones             FOR UPDATE TO cotconv_ejecutor USING (true) WITH CHECK (true);
CREATE POLICY cotconv_upd_inventario       ON public.inventario               FOR UPDATE TO cotconv_ejecutor USING (true) WITH CHECK (true);

-- Transferencia de propiedad de las funciones al rol (requiere poder asumirlo y CREATE en public, solo durante el cambio)
DO $own$
BEGIN
  IF current_setting('server_version_num')::int >= 160000 THEN
    EXECUTE format('GRANT cotconv_ejecutor TO %I WITH SET TRUE', current_user);
  ELSE
    EXECUTE format('GRANT cotconv_ejecutor TO %I', current_user);
  END IF;
END $own$;
GRANT CREATE ON SCHEMA public TO cotconv_ejecutor;

-- ---------------------------------------------------------------- FUNCION PRINCIPAL
CREATE FUNCTION public.convertir_cotizacion_atomica(
  p_id_licencia            text,
  p_cotizacion_id          uuid,
  p_op_clave               text,
  p_cotizacion_updated_at  timestamptz,
  p_pago                   jsonb,
  p_cliente_id             uuid,
  p_entrega                jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  c_min_puntos  constant numeric := 50000;  -- PUNTOS_MIN_COMPRA del dashboard
  c_ratio       constant numeric := 800;    -- PUNTOS_RATIO del dashboard
  c_origenes    constant text[]  := ARRAY['Ahorros Bancolombia','Llave Bancolombia','Nequi','Otro banco'];
  v_huella text; v_prev record; v_cot record; v_cli record; v_inv record;
  v_items jsonb; v_it jsonb; v_n int; v_i int;
  v_prod text; v_tipo text; v_qty int; v_pu numeric; v_pt numeric; v_uds int; v_es_unidad boolean; v_unidades int;
  v_lineas jsonb := '[]'::jsonb; v_req jsonb := '{}'::jsonb; v_ids text[] := '{}';
  v_total numeric := 0; v_desc boolean := false; v_base numeric;
  v_pago_tipo text; v_metodo text; v_origen text; v_estado text; v_abono numeric := 0; v_saldo numeric := 0;
  v_plazo int; v_vence timestamptz; v_medio text; v_total_esperado numeric;
  v_nombre text; v_wa text; v_dir text; v_det text; v_puntos int := 0; v_notas text; v_nom_prod text;
  v_venta_id uuid; v_num int; v_vta record; v_cart record; v_inconsistencia text; v_cartera_id uuid; v_cart_fecha timestamptz; v_pool int; v_rest int; v_res jsonb; k text;
BEGIN
  SET LOCAL lock_timeout = '2s';

  -- 0) Parametros
  IF p_id_licencia IS NULL OR btrim(p_id_licencia) = '' THEN RAISE EXCEPTION 'Licencia no válida.' USING ERRCODE='CV001'; END IF;
  IF p_cotizacion_id IS NULL THEN RAISE EXCEPTION 'Cotización no válida.' USING ERRCODE='CV001'; END IF;
  IF p_op_clave IS NULL OR p_op_clave !~ '^conv-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'Clave de operación no válida.' USING ERRCODE='CV002'; END IF;
  IF p_cotizacion_updated_at IS NULL THEN RAISE EXCEPTION 'Falta la versión de la cotización.' USING ERRCODE='CV001'; END IF;
  IF p_pago IS NULL OR jsonb_typeof(p_pago) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Datos de pago no válidos.' USING ERRCODE='CV040'; END IF;
  IF p_entrega IS NOT NULL AND jsonb_typeof(p_entrega) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Datos de entrega no válidos.' USING ERRCODE='CV001'; END IF;

  v_huella := md5(jsonb_build_object('licencia',p_id_licencia,'cotizacion',p_cotizacion_id,'version',p_cotizacion_updated_at,
                    'pago',p_pago,'cliente',p_cliente_id,'entrega',COALESCE(p_entrega,'{}'::jsonb))::text);

  -- 1) Bloquear la cotizacion de la licencia (serializa dos dispositivos)
  SELECT * INTO v_cot FROM public.cotizaciones WHERE id = p_cotizacion_id AND id_licencia = p_id_licencia FOR UPDATE;
  IF NOT FOUND THEN
    IF EXISTS (SELECT 1 FROM public.cotizacion_conversiones WHERE op_clave = p_op_clave AND id_licencia = p_id_licencia AND cotizacion_id = p_cotizacion_id) THEN
      RAISE EXCEPTION 'La operación ya se confirmó antes, pero la cotización fue eliminada. No se recreó nada ni se descontó inventario.' USING ERRCODE='CV024';
    END IF;
    RAISE EXCEPTION 'La cotización no existe para esta licencia.' USING ERRCODE='CV010';
  END IF;

  -- 2) Idempotencia. El registro solo dice QUE esta operacion existio; la respuesta se arma con
  --    el estado REAL (venta, vinculo, cartera). Nunca se devuelve un resultado guardado sin verificar.
  SELECT * INTO v_prev FROM public.cotizacion_conversiones WHERE op_clave = p_op_clave;
  IF FOUND THEN
    IF v_prev.huella IS DISTINCT FROM v_huella OR v_prev.cotizacion_id <> p_cotizacion_id OR v_prev.id_licencia <> p_id_licencia THEN
      RAISE EXCEPTION 'La clave de operación ya se usó con otros datos. No se registró nada.' USING ERRCODE='CV020';
    END IF;
    SELECT * INTO v_vta FROM public.ventas WHERE id = v_prev.venta_id AND id_cliente = p_id_licencia;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'La operación ya se confirmó antes, pero su venta fue eliminada. No se recreó la venta ni se volvió a descontar inventario.' USING ERRCODE='CV022';
    END IF;
    v_inconsistencia := NULL;
    IF v_vta.cotizacion_id IS DISTINCT FROM p_cotizacion_id THEN v_inconsistencia := 'la venta no pertenece a esta cotización';
    ELSIF v_cot.estado <> 'convertida' OR v_cot.venta_id IS DISTINCT FROM v_vta.id THEN v_inconsistencia := 'la cotización ya no está vinculada a la venta de esta operación';
    END IF;
    SELECT id, total, saldo_pendiente INTO v_cart FROM public.cartera WHERE venta_id = v_vta.id;
    IF v_inconsistencia IS NULL AND v_vta.estado = 'credito' AND NOT FOUND THEN v_inconsistencia := 'falta la cartera de la venta a crédito'; END IF;
    IF v_inconsistencia IS NOT NULL THEN
      RAISE EXCEPTION 'La operación está registrada pero no coincide con el estado actual (%). No se modificó nada: revisión manual.', v_inconsistencia USING ERRCODE='CV023';
    END IF;
    RETURN jsonb_build_object('ok', true, 'venta_id', v_vta.id, 'numero_venta', v_vta.numero_venta, 'estado', v_vta.estado,
      'metodo_pago', v_vta.metodo_pago, 'total', v_vta.total, 'abono', CASE WHEN v_vta.estado = 'credito' THEN COALESCE(v_vta.abono,0) ELSE 0 END,
      'saldo_pendiente', COALESCE(v_vta.saldo_pendiente,0), 'puntos_ganados', COALESCE(v_vta.puntos_ganados,0), 'cartera_id', v_cart.id,
      'repetida', true, 'verificada', true);
  END IF;

  -- 3) Estado de la cotizacion
  IF v_cot.estado <> 'aprobada' OR v_cot.venta_id IS NOT NULL THEN
    RAISE EXCEPTION 'La cotización ya no está disponible para conversión (estado: %).', v_cot.estado USING ERRCODE='CV011'; END IF;
  IF v_cot.updated_at IS DISTINCT FROM p_cotizacion_updated_at THEN
    RAISE EXCEPTION 'La cotización cambió después de abrir el resumen. Vuelve a abrirlo.' USING ERRCODE='CV012'; END IF;
  IF EXISTS (SELECT 1 FROM public.ventas WHERE cotizacion_id = p_cotizacion_id) THEN
    RAISE EXCEPTION 'Ya existe una venta para esta cotización.' USING ERRCODE='CV013'; END IF;

  -- 4) Lineas: validacion y bloqueo del inventario (orden fijo por id: evita interbloqueos)
  v_items := v_cot.items;
  IF v_items IS NULL OR jsonb_typeof(v_items) IS DISTINCT FROM 'array' OR jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'La cotización no tiene productos.' USING ERRCODE='CV030'; END IF;
  v_n := jsonb_array_length(v_items);
  FOR v_i IN 0 .. v_n-1 LOOP
    v_prod := NULLIF(btrim(COALESCE(v_items->v_i->>'prod_id','')),'');
    IF v_prod IS NULL THEN RAISE EXCEPTION 'Línea %: no está vinculada a un producto.', v_i+1 USING ERRCODE='CV031'; END IF;
    IF NOT v_prod = ANY(v_ids) THEN v_ids := v_ids || v_prod; END IF;
  END LOOP;
  PERFORM 1 FROM public.inventario WHERE id = ANY(v_ids) AND id_licencia = p_id_licencia ORDER BY id FOR UPDATE;

  FOR v_i IN 0 .. v_n-1 LOOP
    v_it := v_items->v_i;
    v_prod := btrim(v_it->>'prod_id');
    SELECT id, nombre, categoria, COALESCE(stock,0) AS stock, COALESCE(uds_sueltas,0) AS sueltas, COALESCE(uds_empaque,1) AS uds
      INTO v_inv FROM public.inventario WHERE id = v_prod AND id_licencia = p_id_licencia;
    IF NOT FOUND THEN RAISE EXCEPTION 'Línea % (%): el producto ya no existe.', v_i+1, v_it->>'nombre' USING ERRCODE='CV032'; END IF;
    IF jsonb_typeof(v_it->'cantidad') IS DISTINCT FROM 'number' OR (v_it->>'cantidad') !~ '^[0-9]+$'
       OR (v_it->>'cantidad')::numeric < 1 OR (v_it->>'cantidad')::numeric > 100000 THEN
      RAISE EXCEPTION 'Línea % (%): cantidad no válida.', v_i+1, v_it->>'nombre' USING ERRCODE='CV033'; END IF;
    v_qty := (v_it->>'cantidad')::int;
    IF jsonb_typeof(v_it->'precio_unitario') IS DISTINCT FROM 'number' OR jsonb_typeof(v_it->'precio_total') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Línea % (%): precio no válido.', v_i+1, v_it->>'nombre' USING ERRCODE='CV034'; END IF;
    v_pu := (v_it->>'precio_unitario')::numeric; v_pt := (v_it->>'precio_total')::numeric;
    IF v_pu < 0 OR v_pt < 0 OR abs(v_pt - v_qty*v_pu) > 1 THEN
      RAISE EXCEPTION 'Línea % (%): el precio cotizado es inconsistente.', v_i+1, v_it->>'nombre' USING ERRCODE='CV034'; END IF;
    v_uds := v_inv.uds;
    IF v_uds < 1 THEN RAISE EXCEPTION 'Línea % (%): tamaño de empaque no válido en inventario.', v_i+1, v_it->>'nombre' USING ERRCODE='CV035'; END IF;
    v_tipo := v_it->>'tipo';
    IF v_tipo = 'und' THEN v_es_unidad := true;
    ELSIF v_tipo = 'emp' THEN
      IF v_uds <= 1 THEN RAISE EXCEPTION 'Línea % (%): se cotizó como empaque, pero hoy el producto no tiene empaque.', v_i+1, v_it->>'nombre' USING ERRCODE='CV036'; END IF;
      v_es_unidad := false;
    ELSIF v_tipo IS NULL OR v_tipo = '' THEN
      IF v_uds > 1 THEN RAISE EXCEPTION 'Línea % (%): no indica si se cotizó por unidad o por empaque (x%).', v_i+1, v_it->>'nombre', v_uds USING ERRCODE='CV036'; END IF;
      v_es_unidad := false;
    ELSE RAISE EXCEPTION 'Línea % (%): tipo de venta desconocido.', v_i+1, v_it->>'nombre' USING ERRCODE='CV036';
    END IF;
    v_unidades := CASE WHEN v_es_unidad THEN v_qty ELSE v_qty*v_uds END;
    v_req := jsonb_set(v_req, ARRAY[v_prod], to_jsonb(COALESCE((v_req->>v_prod)::int,0) + v_unidades));
    v_total := v_total + v_pt;
    -- Descuento por linea: descItem > 0, o precio menor que el precio base (lineas antiguas)
    IF jsonb_typeof(v_it->'descItem') = 'number' AND (v_it->>'descItem')::numeric > 0 THEN v_desc := true; END IF;
    IF jsonb_typeof(v_it->'_precioBase') = 'number' THEN
      v_base := (v_it->>'_precioBase')::numeric;
      IF v_base > 0 AND v_pu < v_base - 0.5 THEN v_desc := true; END IF;
    END IF;
    v_lineas := v_lineas || jsonb_build_object('prod_id',v_prod,'nombre',COALESCE(v_it->>'nombre',v_inv.nombre),'categoria',COALESCE(v_inv.categoria,''),
      'cantidad',v_qty,'pu',v_pu,'pt',v_pt,'es_unidad',v_es_unidad,'uds',v_uds);
  END LOOP;

  -- Stock suficiente por producto (unidades de todas sus lineas)
  FOR k IN SELECT jsonb_object_keys(v_req) LOOP
    SELECT COALESCE(stock,0)*COALESCE(uds_empaque,1) + COALESCE(uds_sueltas,0), nombre INTO v_pool, v_nom_prod
      FROM public.inventario WHERE id = k AND id_licencia = p_id_licencia;
    IF v_pool < (v_req->>k)::int THEN
      RAISE EXCEPTION 'Stock insuficiente de % (hay % und, se necesitan %).', v_nom_prod, v_pool, (v_req->>k)::int USING ERRCODE='CV037'; END IF;
  END LOOP;
  IF NOT (v_total > 0) THEN RAISE EXCEPTION 'El total de la venta debe ser mayor que cero.' USING ERRCODE='CV040'; END IF;
  IF p_pago ? 'total_esperado' THEN
    IF jsonb_typeof(p_pago->'total_esperado') IS DISTINCT FROM 'number' THEN RAISE EXCEPTION 'Total esperado no válido.' USING ERRCODE='CV040'; END IF;
    v_total_esperado := (p_pago->>'total_esperado')::numeric;
    IF abs(v_total_esperado - v_total) > 0.005 THEN
      RAISE EXCEPTION 'El total cambió (% en el resumen, % en la base).', v_total_esperado, v_total USING ERRCODE='CV012'; END IF;
  END IF;

  -- 5) Cliente: si se indica ficha, sus datos salen de la base (no del navegador)
  IF p_cliente_id IS NOT NULL THEN
    SELECT * INTO v_cli FROM public.clientes_frecuentes WHERE id = p_cliente_id AND id_licencia = p_id_licencia;
    IF NOT FOUND THEN RAISE EXCEPTION 'La ficha del cliente no existe para esta licencia.' USING ERRCODE='CV041'; END IF;
    v_nombre := v_cli.nombre; v_wa := NULLIF(btrim(COALESCE(v_cli.whatsapp,'')),'');
  ELSE
    v_nombre := v_cot.cliente_nombre; v_wa := NULLIF(btrim(COALESCE(v_cot.cliente_whatsapp,'')),'');
  END IF;

  -- 6) Pago (mismas reglas que el hotfix y el POS)
  v_pago_tipo := p_pago->>'tipo';
  IF v_pago_tipo = 'efectivo' THEN v_metodo := 'efectivo'; v_estado := 'completada';
  ELSIF v_pago_tipo = 'transferencia' THEN
    v_origen := p_pago->>'origen';
    IF v_origen IS NULL OR NOT v_origen = ANY(c_origenes) THEN RAISE EXCEPTION 'Elige el origen de la transferencia.' USING ERRCODE='CV042'; END IF;
    v_metodo := 'transferencia'; v_estado := 'completada';
  ELSIF v_pago_tipo = 'credito' THEN
    IF p_pago ? 'abono' AND jsonb_typeof(p_pago->'abono') NOT IN ('number','null') THEN RAISE EXCEPTION 'El abono inicial no es válido.' USING ERRCODE='CV043'; END IF;
    v_abono := COALESCE((p_pago->>'abono')::numeric, 0);
    IF v_abono < 0 THEN RAISE EXCEPTION 'El abono inicial no es válido.' USING ERRCODE='CV043'; END IF;
    IF v_abono > v_total + 0.005 THEN RAISE EXCEPTION 'El abono inicial supera el total.' USING ERRCODE='CV043'; END IF;
    IF v_abono > 0 THEN
      v_medio := p_pago->>'medio_abono';
      IF v_medio IS NULL OR v_medio NOT IN ('efectivo','transferencia') THEN RAISE EXCEPTION 'Elige el medio del abono inicial.' USING ERRCODE='CV044'; END IF;
      IF v_medio = 'transferencia' THEN
        v_origen := p_pago->>'origen_abono';
        IF v_origen IS NULL OR NOT v_origen = ANY(c_origenes) THEN RAISE EXCEPTION 'Elige el origen de la transferencia del abono.' USING ERRCODE='CV044'; END IF;
      END IF;
    END IF;
    IF v_abono > 0 AND abs(v_abono - v_total) <= 0.005 THEN
      -- El pago cubre el total: venta de contado
      v_metodo := v_medio; v_estado := 'completada'; v_abono := 0;
    ELSE
      IF p_cliente_id IS NULL THEN RAISE EXCEPTION 'El crédito exige un cliente registrado e identificado.' USING ERRCODE='CV045'; END IF;
      IF jsonb_typeof(p_pago->'plazo') IS DISTINCT FROM 'number' OR (p_pago->>'plazo') !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'Plazo de crédito no válido.' USING ERRCODE='CV046'; END IF;
      v_plazo := (p_pago->>'plazo')::int;
      IF v_plazo < 1 OR v_plazo > 365 THEN RAISE EXCEPTION 'El plazo del crédito debe ser de 1 a 365 días.' USING ERRCODE='CV046'; END IF;
      v_metodo := CASE WHEN v_abono > 0 THEN v_medio ELSE 'efectivo' END;
      v_estado := 'credito'; v_saldo := v_total - v_abono; v_vence := now() + make_interval(days => v_plazo);
    END IF;
  ELSE RAISE EXCEPTION 'Elige la forma de pago.' USING ERRCODE='CV040';
  END IF;
  IF v_origen IS NOT NULL THEN v_notas := 'Origen: ' || v_origen; END IF;

  -- 7) Puntos (solo el valor de ventas.puntos_ganados; no se acreditan al cliente).
  --    Exclusiones del POS: credito, descuento, sin WhatsApp, bajo el minimo.
  --    (es_mayorista no existe en clientes_frecuentes de produccion.)
  IF v_estado <> 'credito' AND NOT v_desc AND v_wa IS NOT NULL AND v_total >= c_min_puntos THEN
    v_puntos := floor(v_total / c_ratio)::int; END IF;

  -- 8) Entrega (lo confirmado en el resumen)
  v_dir := NULLIF(btrim(COALESCE(p_entrega->>'direccion','')),'');
  v_det := NULLIF(btrim(COALESCE(p_entrega->>'detalle','')),'');
  IF length(COALESCE(v_dir,'')) > 300 OR length(COALESCE(v_det,'')) > 300 THEN
    RAISE EXCEPTION 'La dirección o el detalle son demasiado largos.' USING ERRCODE='CV047'; END IF;

  -- 9) Escrituras (todas en esta transaccion)
  INSERT INTO public.ventas (id_cliente, cliente_nombre, cliente_whatsapp, total, subtotal, descuento, metodo_pago, estado,
                      puntos_ganados, domicilio, direccion_entrega, detalle_entrega, cotizacion_id, notas,
                      abono, saldo_pendiente, fecha_vencimiento_cartera)
  VALUES (p_id_licencia, v_nombre, v_wa, v_total, v_total, 0, v_metodo, v_estado, v_puntos, 0, v_dir, v_det, p_cotizacion_id, v_notas,
          CASE WHEN v_estado='credito' THEN v_abono ELSE 0 END, CASE WHEN v_estado='credito' THEN v_saldo ELSE 0 END, v_vence)
  RETURNING id, numero_venta INTO v_venta_id, v_num;

  INSERT INTO public.detalle_ventas (venta_id, prod_id, producto_nombre, categoria, cantidad, precio_unitario, precio_total, es_unidad, uds_empaque)
  SELECT v_venta_id, l->>'prod_id', l->>'nombre', l->>'categoria', (l->>'cantidad')::int, (l->>'pu')::numeric, (l->>'pt')::numeric,
         (l->>'es_unidad')::boolean, (l->>'uds')::int
    FROM jsonb_array_elements(v_lineas) AS l;

  FOR k IN SELECT jsonb_object_keys(v_req) LOOP
    SELECT COALESCE(stock,0) AS stock, COALESCE(uds_sueltas,0) AS sueltas, COALESCE(uds_empaque,1) AS uds INTO v_inv
      FROM public.inventario WHERE id = k AND id_licencia = p_id_licencia;
    v_rest := v_inv.stock*v_inv.uds + v_inv.sueltas - (v_req->>k)::int;
    UPDATE public.inventario SET stock = v_rest / v_inv.uds, uds_sueltas = v_rest % v_inv.uds
     WHERE id = k AND id_licencia = p_id_licencia;
  END LOOP;

  IF v_estado = 'credito' AND v_saldo > 0 THEN
    INSERT INTO public.cartera (id_licencia, venta_id, numero_venta, cliente_nombre, cliente_whatsapp, total, saldo_pendiente,
                         fecha_vencimiento, estado_cartera)
    VALUES (p_id_licencia, v_venta_id, v_num, v_nombre, v_wa, v_total, v_saldo, v_vence, 'activa')
    RETURNING id, fecha_creacion INTO v_cartera_id, v_cart_fecha;
    IF v_abono > 0 THEN
      -- Fila espejo del abono inicial con la fecha de la cartera (regla de registrar_abono_cartera_atomico)
      INSERT INTO public.cartera_abonos (id_licencia, cartera_id, venta_id, monto, fecha, registrado_por, medio_pago)
      VALUES (p_id_licencia, v_cartera_id, v_venta_id, v_abono, v_cart_fecha, 'pos', v_medio);
    END IF;
  END IF;

  UPDATE public.cotizaciones SET estado = 'convertida', venta_id = v_venta_id, updated_at = now(),
         cliente_nombre = v_nombre, cliente_whatsapp = v_wa
   WHERE id = p_cotizacion_id AND id_licencia = p_id_licencia;

  v_res := jsonb_build_object('ok', true, 'venta_id', v_venta_id, 'numero_venta', v_num, 'estado', v_estado,
    'metodo_pago', v_metodo, 'total', v_total, 'abono', CASE WHEN v_estado='credito' THEN v_abono ELSE 0 END,
    'saldo_pendiente', v_saldo, 'puntos_ganados', v_puntos, 'cartera_id', v_cartera_id, 'repetida', false, 'verificada', true);
  INSERT INTO public.cotizacion_conversiones (op_clave, id_licencia, cotizacion_id, venta_id, huella, resultado)
  VALUES (p_op_clave, p_id_licencia, p_cotizacion_id, v_venta_id, v_huella, v_res);
  RETURN v_res;
EXCEPTION
  WHEN lock_not_available THEN
    RAISE EXCEPTION 'Otra operación está usando esta cotización o sus productos. No se registró nada; inténtalo de nuevo.' USING ERRCODE='CV050';
END;
$fn$;

-- ---------------------------------------------------------------- FUNCION DE DIAGNOSTICO (solo lectura)
CREATE FUNCTION public.cotizacion_conversion_info(p_id_licencia text, p_cotizacion_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $inf$
  SELECT jsonb_build_object('operaciones', COALESCE(jsonb_agg(jsonb_build_object(
           'venta_id', c.venta_id, 'creada', c.created_at,
           'venta_existe', EXISTS (SELECT 1 FROM public.ventas v WHERE v.id = c.venta_id AND v.id_cliente = c.id_licencia)
         ) ORDER BY c.created_at), '[]'::jsonb))
    FROM public.cotizacion_conversiones c
   WHERE c.id_licencia = p_id_licencia AND c.cotizacion_id = p_cotizacion_id;
$inf$;

-- ---------------------------------------------------------------- DUEÑO, PERMISOS DE EJECUCION Y LIMPIEZA
ALTER FUNCTION public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb) OWNER TO cotconv_ejecutor;
ALTER FUNCTION public.cotizacion_conversion_info(text,uuid) OWNER TO cotconv_ejecutor;
REVOKE CREATE ON SCHEMA public FROM cotconv_ejecutor;
REVOKE ALL ON FUNCTION public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cotizacion_conversion_info(text,uuid) FROM PUBLIC, anon, authenticated;
-- ENSAYO H1: EXECUTE solo para authenticated. anon NO lo recibe en ningun momento de esta transaccion.
GRANT EXECUTE ON FUNCTION public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cotizacion_conversion_info(text,uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.cotizacion_conversion_info(text,uuid) FROM anon;
-- La funcion del disparador tampoco debe quedar ejecutable por PUBLIC/anon/authenticated (un disparador no la necesita para dispararse).
REVOKE ALL ON FUNCTION public.cotconv_registro_inmutable() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb)
  IS 'Hotfix cotizaciones: conversion atomica e idempotente (verifica el estado real en los reintentos).';
COMMENT ON FUNCTION public.cotizacion_conversion_info(text,uuid) IS 'Hotfix cotizaciones: operaciones registradas de una cotizacion (solo lectura).';
DO $rm$
BEGIN  -- el instalador ya no necesita poder asumir el rol: se retira y, si falla, se deshace TODA la instalacion (sin tolerar el error)
  EXECUTE format('REVOKE cotconv_ejecutor FROM %I', current_user);
END $rm$;

-- ---------------------------------------------------------------- VERIFICACION (si algo no cumple, se deshace TODA la instalacion)
DO $post$
DECLARE r regrole; f text; t text; c text; priv text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb)','public.cotizacion_conversion_info(text,uuid)'] LOOP
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure) THEN RAISE EXCEPTION 'VERIFICACION: % debe ser SECURITY DEFINER', f; END IF;
    IF (SELECT proowner::regrole::text FROM pg_proc WHERE oid = f::regprocedure) <> 'cotconv_ejecutor' THEN RAISE EXCEPTION 'VERIFICACION: % debe pertenecer a cotconv_ejecutor', f; END IF;
    IF NOT (SELECT proconfig @> ARRAY['search_path=public, pg_temp'] FROM pg_proc WHERE oid = f::regprocedure) THEN RAISE EXCEPTION 'VERIFICACION: % sin search_path fijo', f; END IF;
    IF has_function_privilege('public', f::regprocedure, 'EXECUTE') THEN RAISE EXCEPTION 'VERIFICACION: PUBLIC no debe ejecutar %', f; END IF;
    IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN RAISE EXCEPTION 'VERIFICACION (ensayo H1): anon no debe ejecutar %', f; END IF;
    IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN RAISE EXCEPTION 'VERIFICACION (ensayo H1): authenticated debe ejecutar %', f; END IF;
  END LOOP;
  -- anon/authenticated: NINGUN privilegio sobre el registro
  FOREACH r IN ARRAY ARRAY['anon'::regrole, 'authenticated'::regrole] LOOP
    FOREACH priv IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] LOOP
      IF has_table_privilege(r, 'public.cotizacion_conversiones', priv) THEN RAISE EXCEPTION 'VERIFICACION: % no debe tener % sobre cotizacion_conversiones', r, priv; END IF;
    END LOOP;
  END LOOP;
  -- cotconv_ejecutor: sin DELETE, TRUNCATE ni UPDATE sobre el registro; sin DELETE/TRUNCATE en ninguna tabla
  FOREACH t IN ARRAY ARRAY['cotizaciones','clientes_frecuentes','inventario','ventas','detalle_ventas','cartera','cartera_abonos','cotizacion_conversiones'] LOOP
    FOREACH priv IN ARRAY ARRAY['DELETE','TRUNCATE','REFERENCES','TRIGGER'] LOOP
      IF has_table_privilege('cotconv_ejecutor', 'public.'||t, priv) THEN RAISE EXCEPTION 'VERIFICACION: cotconv_ejecutor no debe tener % sobre %', priv, t; END IF;
    END LOOP;
  END LOOP;
  IF has_table_privilege('cotconv_ejecutor', 'public.cotizacion_conversiones', 'UPDATE') THEN RAISE EXCEPTION 'VERIFICACION: cotconv_ejecutor no debe poder UPDATE el registro'; END IF;
  IF has_table_privilege('cotconv_ejecutor', 'public.clientes_frecuentes', 'INSERT') OR has_table_privilege('cotconv_ejecutor', 'public.clientes_frecuentes', 'UPDATE') THEN
    RAISE EXCEPTION 'VERIFICACION: cotconv_ejecutor no debe escribir clientes_frecuentes'; END IF;
  IF has_schema_privilege('cotconv_ejecutor', 'public', 'CREATE') THEN RAISE EXCEPTION 'VERIFICACION: cotconv_ejecutor no debe tener CREATE en public'; END IF;
  -- ENSAYO H1: ninguna funcion del hotfix (incluida la del disparador) ejecutable por anon, authenticated ni PUBLIC, salvo las dos RPC para authenticated
  IF has_function_privilege('anon', 'public.cotconv_registro_inmutable()'::regprocedure, 'EXECUTE') OR has_function_privilege('authenticated', 'public.cotconv_registro_inmutable()'::regprocedure, 'EXECUTE')
     OR has_function_privilege('public', 'public.cotconv_registro_inmutable()'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFICACION (ensayo H1): la funcion del disparador no debe ser ejecutable por anon, authenticated ni PUBLIC'; END IF;
  -- el instalador no debe conservar la membresia temporal (SET/INHERIT) en el rol ejecutor; un GRANT/REVOKE de EXECUTE sin ella no surte efecto,
  -- por eso los permisos de ejecucion se verifican aqui, antes del COMMIT, con has_function_privilege
  IF EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.roleid = 'cotconv_ejecutor'::regrole AND m.member = current_user::regrole
             AND (current_setting('server_version_num')::int < 160000 OR COALESCE(m.set_option, true) OR COALESCE(m.inherit_option, true))) THEN
    RAISE EXCEPTION 'VERIFICACION: quedo una membresia temporal (SET/INHERIT) de % en cotconv_ejecutor', current_user; END IF;
  FOREACH c IN ARRAY ARRAY['rolsuper','rolcreaterole','rolcreatedb','rolbypassrls','rolcanlogin','rolreplication'] LOOP
    EXECUTE format('SELECT %I FROM pg_roles WHERE rolname = %L', c, 'cotconv_ejecutor') INTO priv;
    IF priv = 't' THEN RAISE EXCEPTION 'VERIFICACION: cotconv_ejecutor no debe tener el atributo %', c; END IF;
  END LOOP;
END $post$;
COMMIT;
