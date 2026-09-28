-- ============================================================================
-- BLOQUE 2.5-B — Pruebas SQL de registrar_abono_cartera_atomico
-- ============================================================================
-- ⚠ SOLO STAGING LOCAL ("lacava_staging"). Nunca en producción.
-- Todo va dentro de BEGIN ... ROLLBACK: no queda ningún dato persistido.
-- Tenants de prueba falsos ('TEST_TENANT_25B', 'OTRO_TENANT_25B').
-- La concurrencia real (dos sesiones) se prueba aparte con procesos psql
-- independientes: un script de una sola sesión no puede demostrar bloqueos.
-- ============================================================================
BEGIN;

-- Crea venta + cartera coherentes. p_espejo: el abono inicial existe como fila en
-- cartera_abonos (como lo deja saveCarteraLocal). p_saldo/p_estado: forzar valores.
CREATE FUNCTION pg_temp.nueva_cartera(p_tenant text, p_total numeric, p_abono_ini numeric,
  p_espejo boolean DEFAULT true, p_saldo numeric DEFAULT NULL, p_estado text DEFAULT NULL,
  p_estado_venta text DEFAULT 'credito')
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid; c uuid; t timestamptz := now() - interval '1 day'; s numeric;
BEGIN
  INSERT INTO ventas (id_cliente, numero_venta, total, abono, saldo_pendiente, estado, metodo_pago)
    VALUES (p_tenant, 9999, p_total, p_abono_ini, p_total - p_abono_ini, p_estado_venta, 'efectivo') RETURNING id INTO v;
  s := COALESCE(p_saldo, greatest(0, p_total - CASE WHEN p_espejo THEN p_abono_ini ELSE p_abono_ini END));
  INSERT INTO cartera (id_licencia, venta_id, numero_venta, cliente_nombre, total, saldo_pendiente, fecha_creacion, estado_cartera, created_at)
    VALUES (p_tenant, v, 9999, 'Cliente prueba', p_total, s, t, COALESCE(p_estado, CASE WHEN s <= 0 THEN 'pagada' ELSE 'activa' END), t)
    RETURNING id INTO c;
  IF p_espejo AND p_abono_ini > 0 THEN
    INSERT INTO cartera_abonos (id_licencia, cartera_id, venta_id, monto, fecha, registrado_por, created_at, medio_pago)
      VALUES (p_tenant, c, v, p_abono_ini, t, 'pos', t, 'efectivo');
  END IF;
  RETURN c;
END $f$;

-- Llama a la RPC y devuelve 'OK' o el SQLSTATE del error (la llamada fallida se revierte sola).
CREATE FUNCTION pg_temp.intentar(p_c uuid, p_tenant text, p_monto numeric,
  p_fecha timestamptz DEFAULT now(), p_medio text DEFAULT 'efectivo')
RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM registrar_abono_cartera_atomico(p_c, p_tenant, p_monto, p_fecha, p_medio);
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $f$;

CREATE FUNCTION pg_temp.huella(p_c uuid) RETURNS text LANGUAGE sql AS $f$
  SELECT (SELECT saldo_pendiente::text || '/' || estado_cartera FROM cartera WHERE id = p_c) || ' | abonos=' ||
         (SELECT count(*) || ' suma=' || COALESCE(sum(monto), 0) FROM cartera_abonos WHERE cartera_id = p_c)
$f$;

-- R1/R10 — abono PARCIAL sobre cartera con abono inicial (espejo): 500k, inicial 200k, abono 100k
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000); r jsonb; BEGIN
  r := registrar_abono_cartera_atomico(c, 'TEST_TENANT_25B', 100000, now(), 'transferencia');
  ASSERT (r->>'ok')::boolean AND (r->>'saldo_anterior')::numeric = 300000 AND (r->>'saldo_nuevo')::numeric = 200000
     AND r->>'estado_nuevo' = 'activa' AND (r->>'abono_registrado')::numeric = 100000 AND r->>'abono_id' IS NOT NULL, 'R1 retorno: ' || r::text;
  ASSERT pg_temp.huella(c) = '200000/activa | abonos=2 suma=300000', 'R1 base: ' || pg_temp.huella(c);
  ASSERT (SELECT medio_pago || '/' || registrado_por FROM cartera_abonos WHERE id = (r->>'abono_id')::uuid) = 'transferencia/pos', 'R1 abono guardado';
  RAISE NOTICE 'R1  parcial (500k, inicial 200k, abono 100k => 200k activa): PASS';
END $$;

-- R2 — abono EXACTO: completa la deuda => saldo 0, pagada
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000); r jsonb; BEGIN
  r := registrar_abono_cartera_atomico(c, 'TEST_TENANT_25B', 300000, now(), 'efectivo');
  ASSERT (r->>'saldo_nuevo')::numeric = 0 AND r->>'estado_nuevo' = 'pagada', 'R2: ' || r::text;
  ASSERT pg_temp.huella(c) = '0/pagada | abonos=2 suma=500000', 'R2 base: ' || pg_temp.huella(c);
  RAISE NOTICE 'R2  exacto (abono 300k => 0 pagada): PASS';
END $$;

-- R3 — cartera YA PAGADA rechaza abonos, sin tocar nada
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 500000); h text; BEGIN
  h := pg_temp.huella(c);
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', 1000) = 'LC024', 'R3 codigo';
  ASSERT pg_temp.huella(c) = h, 'R3 sin cambios';
  RAISE NOTICE 'R3  cartera pagada => LC024, sin cambios: PASS';
END $$;

-- R4 — SOBREPAGO: abono mayor al saldo => LC025, sin cambios
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000); h text; BEGIN
  h := pg_temp.huella(c);
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', 300001) = 'LC025', 'R4 codigo';
  ASSERT pg_temp.huella(c) = h, 'R4 sin cambios';
  RAISE NOTICE 'R4  sobrepago (300001 sobre saldo 300000) => LC025, sin cambios: PASS';
END $$;

-- R5/R6 — monto 0, negativo y NULL => LC020
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000); h text; BEGIN
  h := pg_temp.huella(c);
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', 0) = 'LC020', 'R5 cero';
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', -5000) = 'LC020', 'R6 negativo';
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', NULL) = 'LC020', 'R6 null';
  ASSERT pg_temp.huella(c) = h, 'R5/R6 sin cambios';
  RAISE NOTICE 'R5  monto 0 => LC020: PASS';
  RAISE NOTICE 'R6  monto negativo / NULL => LC020: PASS';
END $$;

-- R7 — cartera INEXISTENTE => LC021
DO $$ BEGIN
  ASSERT pg_temp.intentar(gen_random_uuid(), 'TEST_TENANT_25B', 1000) = 'LC021', 'R7';
  RAISE NOTICE 'R7  cartera inexistente => LC021: PASS';
END $$;

-- R8 — TENANT incorrecto: cartera de A, llamada como B => LC021, sin cambios
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000); h text; BEGIN
  h := pg_temp.huella(c);
  ASSERT pg_temp.intentar(c, 'OTRO_TENANT_25B', 1000) = 'LC021', 'R8 codigo';
  ASSERT pg_temp.huella(c) = h, 'R8 sin cambios';
  RAISE NOTICE 'R8  tenant incorrecto => LC021, sin cambios: PASS';
END $$;

-- R9/R12 — MÚLTIPLES abonos secuenciales: 100k x3 => 200k, 100k, 0 pagada
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000); r1 jsonb; r2 jsonb; r3 jsonb; BEGIN
  r1 := registrar_abono_cartera_atomico(c, 'TEST_TENANT_25B', 100000, now(), 'efectivo');
  r2 := registrar_abono_cartera_atomico(c, 'TEST_TENANT_25B', 100000, now(), 'nequi');
  r3 := registrar_abono_cartera_atomico(c, 'TEST_TENANT_25B', 100000, now(), 'daviplata');
  ASSERT (r1->>'saldo_nuevo')::numeric = 200000 AND (r2->>'saldo_nuevo')::numeric = 100000
     AND (r3->>'saldo_nuevo')::numeric = 0 AND r3->>'estado_nuevo' = 'pagada', 'R9 secuencia';
  ASSERT pg_temp.huella(c) = '0/pagada | abonos=4 suma=500000', 'R9 base: ' || pg_temp.huella(c);
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', 1) = 'LC024', 'R9 tras pagar';
  RAISE NOTICE 'R9  multiples abonos (100k x3 => 0 pagada, 4 filas = total): PASS';
END $$;

-- R11 — cartera SIN abono inicial ni abonos previos (venta a credito con abono 0)
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 80000, 0); r jsonb; BEGIN
  r := registrar_abono_cartera_atomico(c, 'TEST_TENANT_25B', 30000, now(), 'efectivo');
  ASSERT (r->>'saldo_nuevo')::numeric = 50000 AND r->>'estado_nuevo' = 'activa', 'R11: ' || r::text;
  RAISE NOTICE 'R11 cartera sin abonos previos (80k, abono 30k => 50k activa): PASS';
END $$;

-- R13 — PENDIENTE DE CONCILIACIÓN => LC023, sin cambios. (a) abono inicial fuera del
--       libro, patron de las 65 del BLOQUE 2.5 (caso real #247: 3.380.000, inicial
--       3.000.000, un abono de 380.000, saldo mostrado 3.000.000); (b) saldo guardado
--       distinto del historial; (c) estado incoherente; (d) total cartera != venta.
DO $$ DECLARE a uuid; b uuid; c uuid; d uuid; ha text; BEGIN
  a := pg_temp.nueva_cartera('TEST_TENANT_25B', 3380000, 3000000, false, 3000000, 'activa');
  INSERT INTO cartera_abonos (id_licencia, cartera_id, venta_id, monto, fecha, registrado_por, medio_pago)
    SELECT 'TEST_TENANT_25B', id, venta_id, 380000, now(), 'pos', 'transferencia' FROM cartera WHERE id = a;
  ha := pg_temp.huella(a);
  ASSERT pg_temp.intentar(a, 'TEST_TENANT_25B', 1000) = 'LC023', 'R13a';
  ASSERT pg_temp.huella(a) = ha, 'R13a sin cambios';
  b := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000, true, 250000, 'activa');
  ASSERT pg_temp.intentar(b, 'TEST_TENANT_25B', 1000) = 'LC023', 'R13b';
  c := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000, true, NULL, 'pagada');
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', 1000) = 'LC023', 'R13c';
  d := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000);
  UPDATE ventas SET total = 600000 WHERE id = (SELECT venta_id FROM cartera WHERE id = d);
  ASSERT pg_temp.intentar(d, 'TEST_TENANT_25B', 1000) = 'LC023', 'R13d';
  RAISE NOTICE 'R13 pendiente de conciliacion (inicial fuera del libro / saldo / estado / total) => LC023: PASS';
END $$;

-- R14 — venta asociada de OTRO tenant o que no es credito => LC022
DO $$ DECLARE a uuid; b uuid; BEGIN
  a := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000);
  UPDATE ventas SET id_cliente = 'OTRO_TENANT_25B' WHERE id = (SELECT venta_id FROM cartera WHERE id = a);
  ASSERT pg_temp.intentar(a, 'TEST_TENANT_25B', 1000) = 'LC022', 'R14a';
  b := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000, true, NULL, NULL, 'completada');
  ASSERT pg_temp.intentar(b, 'TEST_TENANT_25B', 1000) = 'LC022', 'R14b';
  RAISE NOTICE 'R14 venta de otro tenant / no credito => LC022: PASS';
END $$;

-- R15 — fecha NULL => LC028; medio de pago invalido o NULL => LC029
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000); h text; BEGIN
  h := pg_temp.huella(c);
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', 1000, NULL) = 'LC028', 'R15 fecha';
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', 1000, now(), 'bitcoin') = 'LC029', 'R15 medio';
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', 1000, now(), NULL) = 'LC029', 'R15 medio null';
  ASSERT pg_temp.huella(c) = h, 'R15 sin cambios';
  RAISE NOTICE 'R15 fecha NULL => LC028, medio invalido => LC029: PASS';
END $$;

-- R16 — ROLLBACK tras el INSERT: un trigger de prueba hace fallar el UPDATE de
--       cartera (paso posterior al INSERT del abono). Nada debe quedar.
CREATE FUNCTION pg_temp.falla_update() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN RAISE EXCEPTION 'falla simulada en UPDATE de cartera' USING ERRCODE = 'XX999'; END $f$;
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000); h text; n0 bigint; BEGIN
  h := pg_temp.huella(c);
  SELECT count(*) INTO n0 FROM cartera_abonos;
  EXECUTE format('CREATE TRIGGER tg_falla_%s BEFORE UPDATE ON cartera FOR EACH ROW WHEN (OLD.id = %L) EXECUTE FUNCTION pg_temp.falla_update()', replace(c::text, '-', ''), c);
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', 100000) = 'XX999', 'R16 debia fallar';
  ASSERT pg_temp.huella(c) = h, 'R16 residuos: ' || pg_temp.huella(c) || ' vs ' || h;
  ASSERT (SELECT count(*) FROM cartera_abonos) = n0, 'R16 abono huerfano';
  EXECUTE format('DROP TRIGGER tg_falla_%s ON cartera', replace(c::text, '-', ''));
  RAISE NOTICE 'R16 rollback tras INSERT (falla el UPDATE) => 0 residuos: PASS';
END $$;

-- R17 — INTEGRIDAD (BLOQUE 2.5-B.2): en una secuencia de abonos validos e invalidos
--       (a) ventas NO cambia; (b) un abono nunca sube el saldo; (c) el invariante
--       saldo = total - SUM(abonos) se cumple siempre; (d) cada abono tiene el venta_id y
--       el tenant de su cartera; (e) nunca hay saldo negativo ni estado incoherente.
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 700000, 100000); hv text; r jsonb; m numeric; BEGIN
  SELECT md5(string_agg(t::text, '|' ORDER BY t.id)) INTO hv FROM ventas t;
  FOREACH m IN ARRAY ARRAY[50000, 0, 999999, 150000, -1, 200000, 200001, 200000]::numeric[] LOOP
    IF pg_temp.intentar(c, 'TEST_TENANT_25B', m) = 'OK' THEN NULL; END IF;
  END LOOP;
  ASSERT (SELECT md5(string_agg(t::text, '|' ORDER BY t.id)) FROM ventas t) = hv, 'R17a ventas cambio';
  -- aceptados: 50k, 150k, 200k, 200k (+ la fila del abono inicial de 100k) = 5 filas, 700k
  ASSERT pg_temp.huella(c) = '0/pagada | abonos=5 suma=700000', 'R17 resultado: ' || pg_temp.huella(c);
  ASSERT NOT EXISTS (SELECT 1 FROM cartera x WHERE x.id_licencia = 'TEST_TENANT_25B'
      AND (x.saldo_pendiente < 0
        OR x.estado_cartera <> CASE WHEN x.saldo_pendiente <= 0 THEN 'pagada' ELSE 'activa' END
        OR x.saldo_pendiente <> greatest(0, x.total - (SELECT COALESCE(sum(monto), 0) FROM cartera_abonos a WHERE a.cartera_id = x.id)))
      AND EXISTS (SELECT 1 FROM cartera_abonos a WHERE a.cartera_id = x.id AND a.registrado_por = 'pos' AND a.created_at > now() - interval '1 hour')
      AND x.id = c), 'R17c/e invariante o estado';
  ASSERT NOT EXISTS (SELECT 1 FROM cartera_abonos a JOIN cartera x ON x.id = a.cartera_id
      WHERE a.cartera_id = c AND (a.venta_id <> x.venta_id OR a.id_licencia <> x.id_licencia OR a.monto <= 0)), 'R17d abono inconsistente';
  -- (b) saldo monotono: la secuencia de abonos aceptados solo puede bajar el saldo
  r := registrar_abono_cartera_atomico(pg_temp.nueva_cartera('TEST_TENANT_25B', 300000, 0), 'TEST_TENANT_25B', 1, now(), 'efectivo');
  ASSERT (r->>'saldo_nuevo')::numeric < (r->>'saldo_anterior')::numeric, 'R17b el abono no bajo el saldo';
  RAISE NOTICE 'R17 integridad (ventas intacta, saldo solo baja, invariante, abonos coherentes, 8 intentos mixtos): PASS';
END $$;

-- R18 — CUENTAS DEL BLOQUE 2.5 (sin repararlas): los 3 patrones reales se rechazan (LC023)
--       y no cambian ni se crea ningun dato. Casos tomados de produccion:
--       29 "criticas"   (#247): activa, saldo = abono de la venta, 1 abono = total - inicial
--       23 "sin abonos" : activa, saldo = total - inicial, 0 abonos en el libro
--       13 "cerradas"   (#367): pagada, 2 abonos = total, uno de ellos igual al inicial
DO $$ DECLARE a uuid; b uuid; c uuid; h text; n0 bigint; BEGIN
  SELECT count(*) INTO n0 FROM cartera_abonos;
  a := pg_temp.nueva_cartera('TEST_TENANT_25B', 3380000, 3000000, false, 3000000, 'activa');
  INSERT INTO cartera_abonos (id_licencia, cartera_id, venta_id, monto, fecha, registrado_por, medio_pago)
    SELECT 'TEST_TENANT_25B', id, venta_id, 380000, now(), 'pos', 'transferencia' FROM cartera WHERE id = a;
  b := pg_temp.nueva_cartera('TEST_TENANT_25B', 900000, 400000, false, 500000, 'activa');
  c := pg_temp.nueva_cartera('TEST_TENANT_25B', 299200, 180000, false, 0, 'pagada');
  INSERT INTO cartera_abonos (id_licencia, cartera_id, venta_id, monto, fecha, registrado_por, medio_pago)
    SELECT 'TEST_TENANT_25B', id, venta_id, m, now(), 'pos', 'transferencia' FROM cartera, unnest(ARRAY[119200, 180000]) m WHERE id = c;
  SELECT count(*) INTO n0 FROM cartera_abonos;
  h := pg_temp.huella(a) || pg_temp.huella(b) || pg_temp.huella(c);
  ASSERT pg_temp.intentar(a, 'TEST_TENANT_25B', 1000) = 'LC023', 'R18 critica';
  ASSERT pg_temp.intentar(a, 'TEST_TENANT_25B', 3000000) = 'LC023', 'R18 critica (monto = deuda fantasma)';
  ASSERT pg_temp.intentar(b, 'TEST_TENANT_25B', 1000) = 'LC023', 'R18 sin abonos';
  ASSERT pg_temp.intentar(b, 'TEST_TENANT_25B', 500000) = 'LC023', 'R18 sin abonos (monto = saldo mostrado)';
  ASSERT pg_temp.intentar(c, 'TEST_TENANT_25B', 1000) = 'LC023', 'R18 cerrada con posible duplicado';
  ASSERT pg_temp.huella(a) || pg_temp.huella(b) || pg_temp.huella(c) = h, 'R18 cambiaron';
  ASSERT (SELECT count(*) FROM cartera_abonos) = n0, 'R18 se crearon abonos';
  RAISE NOTICE 'R18 patrones del BLOQUE 2.5 (29 criticas / 23 sin abonos / 13 cerradas) => LC023, sin cambios ni datos nuevos: PASS';
END $$;

-- R19 — TRIGGER de updated_at como el que evidencian los datos de produccion (updated_at
--       cambia en PATCH que no lo envian). Reproduccion minima SOLO en esta transaccion.
CREATE FUNCTION pg_temp.tg_updated_at() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN NEW.updated_at := clock_timestamp(); RETURN NEW; END $f$;
CREATE TRIGGER tg_updated_at_25b BEFORE UPDATE ON cartera FOR EACH ROW EXECUTE FUNCTION pg_temp.tg_updated_at();
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 500000, 200000); u0 timestamptz; r jsonb; BEGIN
  SELECT updated_at INTO u0 FROM cartera WHERE id = c;
  r := registrar_abono_cartera_atomico(c, 'TEST_TENANT_25B', 300000, now(), 'efectivo');
  ASSERT r->>'estado_nuevo' = 'pagada' AND pg_temp.huella(c) = '0/pagada | abonos=2 suma=500000', 'R19: ' || pg_temp.huella(c);
  ASSERT (SELECT updated_at FROM cartera WHERE id = c) > u0, 'R19 updated_at no avanzo';
  RAISE NOTICE 'R19 con trigger BEFORE UPDATE de updated_at: RPC correcta, updated_at avanza: PASS';
END $$;
DROP TRIGGER tg_updated_at_25b ON cartera;

-- R20 — esquema alineado con produccion: cartera.venta_id es UNIQUE (1 cartera por venta)
DO $$ DECLARE c uuid := pg_temp.nueva_cartera('TEST_TENANT_25B', 100000, 0); ok boolean := false; BEGIN
  BEGIN
    INSERT INTO cartera (id_licencia, venta_id, total, saldo_pendiente, estado_cartera)
      SELECT id_licencia, venta_id, total, saldo_pendiente, estado_cartera FROM cartera WHERE id = c;
  EXCEPTION WHEN unique_violation THEN ok := true;
  END;
  ASSERT ok, 'R20 se permitio una segunda cartera para la misma venta';
  RAISE NOTICE 'R20 UNIQUE(cartera.venta_id) como en produccion: PASS';
END $$;

DO $$ BEGIN RAISE NOTICE '=== BLOQUE 2.5-B: TODAS LAS PRUEBAS SQL COMPLETADAS ==='; END $$;
ROLLBACK;
