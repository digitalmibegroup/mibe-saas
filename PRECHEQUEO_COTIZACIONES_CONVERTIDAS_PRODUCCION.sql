-- PRECHEQUEO DE SOLO LECTURA: estado de los enlaces de las cotizaciones "convertida" (produccion, antes del hotfix de cotizaciones).
-- No escribe nada: un unico SELECT. Pegar completo en el SQL Editor y ejecutar una vez (devuelve una sola tabla, una linea por fila).
--
-- Clasifica cada cotizacion convertida:
--   OK                                       la venta existe, es de la misma licencia y apunta de vuelta a la cotizacion (ventas.cotizacion_id)
--   ENLACE_INVERSO_AUSENTE                   la venta existe y es de la misma licencia, pero ventas.cotizacion_id esta vacio
--   SIN_VENTA_ID                             la cotizacion no tiene venta_id (conversion incompleta)
--   VENTA_ID_INEXISTENTE                     venta_id apunta a una venta que no existe
--   VENTA_OTRA_LICENCIA                      la venta pertenece a otra licencia
--   CONTRADICTORIO                           la venta apunta de vuelta a OTRA cotizacion
--   COMPARTIDO_VARIAS_VENTAS                 mas de una venta apunta a la misma cotizacion
--   COMPARTIDO_VENTA_DE_VARIAS_COTIZACIONES  la misma venta esta vinculada a mas de una cotizacion convertida
--
-- EXCEPCION DOCUMENTADA (unica): las 10 cotizaciones historicas de agosto de 2026 listadas abajo, categoria ENLACE_INVERSO_AUSENTE
-- (verificadas el 2026-11-18 sobre el respaldo de produccion 20261118-143826). No se reparan. Cualquier otra fila no OK, o cualquier
-- diferencia en ese conjunto, da RESULTADO|NO_CONFORME y el despliegue se detiene.
WITH excepcion(id) AS (VALUES
  ('71f5c2bf-386f-49fb-903d-077a6c4c9a5d'::uuid),('3c94d8e6-efea-4ecc-a19f-62f8f1bae070'::uuid),('d2558e2e-a56d-4ae4-9205-1c4d80181619'::uuid),
  ('7bb665e6-178e-4ee8-a10b-5d8d4dffdb03'::uuid),('6a6df08d-aad3-4427-8fff-b5ef8e9460f3'::uuid),('a07cbac7-b248-496a-b05a-c1e5ff2b3f0e'::uuid),
  ('5b8fa3c4-b401-4e90-9df2-79f1af77edf7'::uuid),('200f8968-fbe6-40ea-b2f6-2170efae7d5f'::uuid),('61a4da72-5368-4923-b5e7-080169a44c8c'::uuid),
  ('5d40d4b0-d697-41c1-9ee9-dbecbd721447'::uuid)),
cl AS (
  SELECT c.id, c.id_licencia, c.venta_id, v.id AS v_id, v.cotizacion_id AS v_cot, v.id_cliente AS v_lic,
         (SELECT count(*) FROM public.ventas v2 WHERE v2.cotizacion_id = c.id) AS n_ventas_enlazan,
         (SELECT count(*) FROM public.cotizaciones c2 WHERE c2.estado = 'convertida' AND c2.venta_id = c.venta_id) AS n_cot_misma_venta
    FROM public.cotizaciones c LEFT JOIN public.ventas v ON v.id = c.venta_id
   WHERE c.estado = 'convertida'),
k AS (
  SELECT id, CASE
    WHEN venta_id IS NULL THEN 'SIN_VENTA_ID'
    WHEN v_id IS NULL THEN 'VENTA_ID_INEXISTENTE'
    WHEN v_lic IS DISTINCT FROM id_licencia THEN 'VENTA_OTRA_LICENCIA'
    WHEN n_ventas_enlazan > 1 THEN 'COMPARTIDO_VARIAS_VENTAS'
    WHEN n_cot_misma_venta > 1 THEN 'COMPARTIDO_VENTA_DE_VARIAS_COTIZACIONES'
    WHEN v_cot = id THEN 'OK'
    WHEN v_cot IS NULL THEN 'ENLACE_INVERSO_AUSENTE'
    ELSE 'CONTRADICTORIO' END AS cat
    FROM cl),
cats(cat) AS (VALUES ('OK'),('ENLACE_INVERSO_AUSENTE'),('SIN_VENTA_ID'),('VENTA_ID_INEXISTENTE'),('VENTA_OTRA_LICENCIA'),
                     ('CONTRADICTORIO'),('COMPARTIDO_VARIAS_VENTAS'),('COMPARTIDO_VENTA_DE_VARIAS_COTIZACIONES')),
res AS (
  SELECT (SELECT count(*) FROM k WHERE cat NOT IN ('OK','ENLACE_INVERSO_AUSENTE')) AS otras,
         (SELECT count(*) FROM k WHERE cat = 'ENLACE_INVERSO_AUSENTE') AS n_ausente,
         (SELECT count(*) FROM k WHERE cat = 'ENLACE_INVERSO_AUSENTE' AND id IN (SELECT id FROM excepcion)) AS n_ausente_en_lista,
         (SELECT count(*) FROM excepcion e WHERE EXISTS (SELECT 1 FROM k WHERE k.id = e.id AND k.cat = 'ENLACE_INVERSO_AUSENTE')) AS lista_presente)
SELECT linea FROM (
  SELECT 1 AS o, 'CATEGORIA|' || cats.cat || '|' || (SELECT count(*) FROM k WHERE k.cat = cats.cat) AS linea FROM cats
  UNION ALL
  SELECT 2, 'ENLACE_INVERSO_AUSENTE|' || k.id || '|' || CASE WHEN k.id IN (SELECT id FROM excepcion) THEN 'en_la_lista_documentada' ELSE 'FUERA_DE_LA_LISTA' END
    FROM k WHERE k.cat = 'ENLACE_INVERSO_AUSENTE'
  UNION ALL
  SELECT 3, 'OTRA_ANOMALIA|' || k.id || '|' || k.cat FROM k WHERE k.cat NOT IN ('OK','ENLACE_INVERSO_AUSENTE')
  UNION ALL
  SELECT 4, 'RESULTADO|' || CASE
      WHEN otras = 0 AND n_ausente = 10 AND n_ausente_en_lista = 10 AND lista_presente = 10 THEN 'CONFORME_CON_EXCEPCION_DOCUMENTADA_10'
      ELSE 'NO_CONFORME' END FROM res
) t ORDER BY o, linea;
