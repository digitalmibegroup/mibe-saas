-- ============================================================================
-- BLOQUE 2.5-C — RECUPERACIÓN DE CARTERA CON EVIDENCIA COMPLETA (categoría A)
-- ============================================================================
-- Generado el 2026-09-28T14:44:09.867Z a partir de la foto de producción
-- 2026-09-28T14:39:05.101Z y del respaldo local del 11-ago-2026
-- (lacava_BACKUP_LOCAL_CLIENTE_PRE_MIGRACION_2026-08-11-15-55-35.json).
--
-- QUÉ HACE — 33 carteras que hoy muestran deuda que ya fue pagada:
--   * 29 "críticas": el historial ya tiene el resto del pago; falta SOLO el abono
--     inicial de la venta. Se inserta ese abono (monto = ventas.abono; fecha del respaldo,
--     a < 60 s de la venta).
--   * 4 "sin abonos" cuyo respaldo suma EXACTAMENTE el total: se insertan sus
--     abonos del respaldo con monto y fecha exactos.
--   * En las 33 carteras: saldo_pendiente = 0 y estado_cartera = 'pagada'.
--   Total a insertar: 38 abonos por $33.043.324.
--   Deuda fantasma que desaparece: $29.400.600.
--
-- QUÉ NO HACE: no toca ventas, no borra nada, no modifica ningún abono existente, no
-- toca las 13 cerradas (posible duplicado), ni las 19 "sin abonos" con exceso en el
-- respaldo, ni ninguna otra cartera. medio_pago queda NULL (el respaldo no lo trae; no
-- se inventa). registrado_por = 'recuperacion_respaldo_2026-08-11' (trazable).
--
-- SEGURIDAD — todo es UN SOLO bloque atómico: si cualquier verificación falla, se
-- revierte completo y no queda nada escrito.
--   1. Exige que NO haya ninguna caja abierta (el cierre de caja cuenta los abonos
--      creados durante el turno; estos abonos son históricos).
--   2. No se puede ejecutar dos veces (si ya existen abonos con esa marca, se detiene).
--   3. Bloquea las 33 carteras y verifica que CADA UNA siga exactamente como en la foto
--      (saldo, estado, total, abonos, abono de la venta). Si alguna cambió, se detiene.
--   4. Verifica al final, cuenta por cuenta: abonos = total, saldo 0, pagada y abono
--      inicial reconocible. Si algo no cuadra, se detiene.
-- ============================================================================

DO $recuperacion$
DECLARE
  c_tag       constant text  := 'recuperacion_respaldo_2026-08-11';
  c_esperado  constant jsonb := '[{"cartera_id":"2fcbdde5-ae14-4345-9302-2cf097e64e33","venta_id":"5dc7b20e-b8f7-4dcf-bb33-3d6aa7b8f14d","numero":248,"total":2098500,"abono_venta":1580000,"saldo":1580000,"estado":"activa","n_abonos":1,"suma_abonos":518500,"fecha_creacion":"2026-06-23T11:58:42.178372+00:00"},{"cartera_id":"f2c0a224-0498-4192-85d3-f21e9ba5433c","venta_id":"37c3b9c1-7762-4c98-9c60-73488df6f1bf","numero":244,"total":2911128,"abono_venta":1500000,"saldo":1500000,"estado":"activa","n_abonos":1,"suma_abonos":1411128,"fecha_creacion":"2026-06-22T22:47:17.303763+00:00"},{"cartera_id":"bdff5456-02c3-4e42-aa5c-5295fcc8dfcd","venta_id":"8b9b8573-85b4-4232-8923-6ccc682d7183","numero":247,"total":3380000,"abono_venta":3000000,"saldo":3000000,"estado":"activa","n_abonos":1,"suma_abonos":380000,"fecha_creacion":"2026-06-23T11:56:18.427138+00:00"},{"cartera_id":"2d4acf65-a0d0-40aa-a576-e11a0b39d248","venta_id":"e4a3190f-4147-4d15-a763-7b14403c054e","numero":306,"total":1393932,"abono_venta":1100000,"saldo":1100000,"estado":"activa","n_abonos":1,"suma_abonos":293932,"fecha_creacion":"2026-07-01T23:50:37.952779+00:00"},{"cartera_id":"770d3fae-f8b7-4b44-ab61-2e1a1aa9c1bd","venta_id":"0beaf1b7-e5dd-4ba4-a491-23cd57157441","numero":285,"total":2117144,"abono_venta":1100000,"saldo":1100000,"estado":"activa","n_abonos":1,"suma_abonos":1017144,"fecha_creacion":"2026-06-27T22:06:56.233458+00:00"},{"cartera_id":"bf23317b-9ace-48cf-9afa-36fa111f513f","venta_id":"bb77aa83-b828-4342-9d7e-43fa3cc4fdcb","numero":115,"total":31800,"abono_venta":28000,"saldo":28000,"estado":"activa","n_abonos":1,"suma_abonos":3800,"fecha_creacion":"2026-06-06T01:45:38.246234+00:00"},{"cartera_id":"7ebadab7-6b88-4652-b4b1-f1574c50343b","venta_id":"a0c89279-97a1-44e8-a1bf-3a2316c2279b","numero":116,"total":45600,"abono_venta":28000,"saldo":28000,"estado":"activa","n_abonos":1,"suma_abonos":17600,"fecha_creacion":"2026-06-06T01:47:27.626881+00:00"},{"cartera_id":"2739b564-f206-43f4-bed0-30ac4e216e13","venta_id":"209a1a92-22f3-4b28-b5b4-7e9c418c3563","numero":126,"total":428568,"abono_venta":400000,"saldo":400000,"estado":"activa","n_abonos":1,"suma_abonos":28568,"fecha_creacion":"2026-06-07T00:17:28.267182+00:00"},{"cartera_id":"df33472e-e389-4f1c-9fda-6f7a9199fe2d","venta_id":"955c14e3-bb66-497f-8815-cf2fcc374d7a","numero":139,"total":515930,"abono_venta":250000,"saldo":250000,"estado":"activa","n_abonos":1,"suma_abonos":265930,"fecha_creacion":"2026-06-11T13:55:41.712655+00:00"},{"cartera_id":"177af9a0-8b88-444a-9d04-73c853ae7a9a","venta_id":"a9b126c4-5eee-4719-9e3a-758956c30c81","numero":184,"total":725833,"abono_venta":250000,"saldo":250000,"estado":"activa","n_abonos":1,"suma_abonos":475833,"fecha_creacion":"2026-06-16T17:44:10.119951+00:00"},{"cartera_id":"ee87bb8b-727a-4d9c-8df1-db2d2a807d7f","venta_id":"e57719d4-2489-40b6-a14f-349d52dc3840","numero":185,"total":735732,"abono_venta":350000,"saldo":350000,"estado":"activa","n_abonos":1,"suma_abonos":385732,"fecha_creacion":"2026-06-16T17:46:53.037335+00:00"},{"cartera_id":"1cc0d5d7-0249-4605-95d7-c5c8095b34ae","venta_id":"ecd3af63-4a22-4b2a-a913-45e36e8c0719","numero":193,"total":2484092,"abono_venta":1800000,"saldo":1800000,"estado":"activa","n_abonos":1,"suma_abonos":684092,"fecha_creacion":"2026-06-17T17:01:11.353692+00:00"},{"cartera_id":"1287d14a-d730-48c0-a5f5-f85c87d4d0dc","venta_id":"8c363647-3bc4-48e9-be66-275ece5e6878","numero":200,"total":169405,"abono_venta":160000,"saldo":160000,"estado":"activa","n_abonos":1,"suma_abonos":9405,"fecha_creacion":"2026-06-17T18:01:54.431519+00:00"},{"cartera_id":"c4020dea-ff34-477e-a1a1-5e712f2697bd","venta_id":"ba4ec5c2-471c-4bfa-9564-ad375de3e8c7","numero":211,"total":422138,"abono_venta":220000,"saldo":220000,"estado":"activa","n_abonos":1,"suma_abonos":202138,"fecha_creacion":"2026-06-18T16:51:05.657225+00:00"},{"cartera_id":"dccab523-f578-4db7-8d4d-0b6efbee2e14","venta_id":"8c2eb405-2148-4d89-9cc4-1a4d5f206929","numero":226,"total":308508,"abono_venta":300000,"saldo":300000,"estado":"activa","n_abonos":1,"suma_abonos":8508,"fecha_creacion":"2026-06-19T22:30:28.289595+00:00"},{"cartera_id":"4530860c-b00a-44e0-b9ce-f40291b8ef16","venta_id":"53f01172-df19-45ea-9b66-481f4211bfda","numero":262,"total":1206300,"abono_venta":700000,"saldo":700000,"estado":"activa","n_abonos":1,"suma_abonos":506300,"fecha_creacion":"2026-06-25T19:41:35.952296+00:00"},{"cartera_id":"99b460db-42ad-4682-aff8-abd83229dea3","venta_id":"1d0e5197-9297-4002-959b-e3b5d2395f97","numero":280,"total":820494,"abono_venta":500000,"saldo":500000,"estado":"activa","n_abonos":1,"suma_abonos":320494,"fecha_creacion":"2026-06-27T18:34:04.502438+00:00"},{"cartera_id":"06d90a69-9509-4aa1-8b21-795a50339916","venta_id":"18bd3164-c849-4800-8491-2195b2b39cd2","numero":312,"total":941594,"abono_venta":542000,"saldo":542000,"estado":"activa","n_abonos":1,"suma_abonos":399594,"fecha_creacion":"2026-07-02T20:40:46.01743+00:00"},{"cartera_id":"e807755f-67f9-4409-a35e-a1408ba0127b","venta_id":"a446044f-5ac8-4dfb-a60e-007d7d024df2","numero":313,"total":672511,"abono_venta":542000,"saldo":542000,"estado":"activa","n_abonos":1,"suma_abonos":130511,"fecha_creacion":"2026-07-02T20:43:36.331997+00:00"},{"cartera_id":"852b4536-d412-4c65-963d-d2ef06072173","venta_id":"2ebcf30a-7c31-4ee3-87a6-1d4da25cf655","numero":321,"total":3380000,"abono_venta":1850000,"saldo":1850000,"estado":"activa","n_abonos":1,"suma_abonos":1530000,"fecha_creacion":"2026-07-03T13:17:16.845599+00:00"},{"cartera_id":"4753b6fb-bbb9-44b9-945f-c89b461126d2","venta_id":"cb614535-cf67-4f1d-bff7-da5f3f1f8e28","numero":320,"total":855000,"abono_venta":500000,"saldo":500000,"estado":"activa","n_abonos":1,"suma_abonos":355000,"fecha_creacion":"2026-07-03T13:00:59.9005+00:00"},{"cartera_id":"a4a36fb5-d731-4f3d-9273-5dfe7d698fa9","venta_id":"7ffbe264-be27-4b34-930e-3d21acda2f66","numero":340,"total":7149000,"abono_venta":5000000,"saldo":5000000,"estado":"activa","n_abonos":1,"suma_abonos":2149000,"fecha_creacion":"2026-07-05T10:58:34.250834+00:00"},{"cartera_id":"dd3977a2-3360-4134-a3b3-9da0bb8b1fd2","venta_id":"e35c2d59-f5f6-4d53-8131-936f5d224227","numero":346,"total":2481600,"abono_venta":1700000,"saldo":1700000,"estado":"activa","n_abonos":1,"suma_abonos":781600,"fecha_creacion":"2026-07-07T12:11:07.291412+00:00"},{"cartera_id":"8bd3b88a-3ce1-494d-8865-4085454e4b74","venta_id":"33184b58-f355-4f5c-a7a2-fb86b3633689","numero":347,"total":1696130,"abono_venta":1100000,"saldo":1100000,"estado":"activa","n_abonos":1,"suma_abonos":596130,"fecha_creacion":"2026-07-07T12:16:17.105213+00:00"},{"cartera_id":"9839a7cc-cdfe-4a74-a982-4a100dd0bf49","venta_id":"278c632e-ff2b-4809-9cb7-81ceab1bea82","numero":348,"total":681864,"abono_venta":300000,"saldo":300000,"estado":"activa","n_abonos":1,"suma_abonos":381864,"fecha_creacion":"2026-07-07T12:18:18.932311+00:00"},{"cartera_id":"bbc9aacc-c50d-4900-a5ce-e44fc0ec883e","venta_id":"379f6bc8-9eee-4087-b7f1-69553a386bfe","numero":350,"total":849100,"abono_venta":500000,"saldo":500000,"estado":"activa","n_abonos":1,"suma_abonos":349100,"fecha_creacion":"2026-07-07T12:23:02.904529+00:00"},{"cartera_id":"42ab7b9a-525e-47d6-9290-9cb3976253ce","venta_id":"6685e45f-4083-41fd-a2e6-b214d5a1496e","numero":351,"total":1478000,"abono_venta":850000,"saldo":850000,"estado":"activa","n_abonos":1,"suma_abonos":628000,"fecha_creacion":"2026-07-07T17:03:39.286403+00:00"},{"cartera_id":"0ec1a581-5705-44d6-ab0a-1cf8d2369d1f","venta_id":"ff1fac62-d881-46dc-9d94-848c10f2888d","numero":401,"total":457000,"abono_venta":250000,"saldo":207000,"estado":"activa","n_abonos":0,"suma_abonos":0,"fecha_creacion":"2026-07-15T19:36:18.125657+00:00"},{"cartera_id":"d1c2eab8-f53a-4c15-a254-65e3a0495ba7","venta_id":"ffe9a46a-6b75-43ac-9317-cab147669bcb","numero":415,"total":2209724,"abono_venta":1209724,"saldo":1000000,"estado":"activa","n_abonos":0,"suma_abonos":0,"fecha_creacion":"2026-07-18T22:01:23.056044+00:00"},{"cartera_id":"974dc4f2-2577-479d-b28f-e9f119c4d231","venta_id":"1d15c02c-193a-4a9e-95d4-53110a6d1f81","numero":423,"total":2683000,"abono_venta":1683000,"saldo":1000000,"estado":"activa","n_abonos":0,"suma_abonos":0,"fecha_creacion":"2026-07-19T18:15:33.719683+00:00"},{"cartera_id":"2e9e826f-9518-4425-b8c6-eac04b5d97a4","venta_id":"7644d53b-5d18-4377-b4ee-3024dbde21ad","numero":492,"total":922094,"abono_venta":480000,"saldo":480000,"estado":"activa","n_abonos":1,"suma_abonos":442094,"fecha_creacion":"2026-08-05T02:43:25.110366+00:00"},{"cartera_id":"4b6ebb2a-5aac-4be1-85c4-61afe8cd9acf","venta_id":"f5995ed6-f8c1-4a92-9fae-adcdc747eaba","numero":463,"total":813600,"abono_venta":500000,"saldo":313600,"estado":"activa","n_abonos":0,"suma_abonos":0,"fecha_creacion":"2026-07-31T01:09:37.511855+00:00"},{"cartera_id":"2bbbb4d4-1c20-493c-8fab-824948b4bc3e","venta_id":"afa1797f-9f1c-4ba9-a452-a23d1045bdd8","numero":400,"total":360000,"abono_venta":250000,"saldo":250000,"estado":"activa","n_abonos":1,"suma_abonos":110000,"fecha_creacion":"2026-07-15T19:32:27.098531+00:00"}]'::jsonb;
  c_nuevos    constant jsonb := '[{"cartera_id":"2fcbdde5-ae14-4345-9302-2cf097e64e33","venta_id":"5dc7b20e-b8f7-4dcf-bb33-3d6aa7b8f14d","monto":1580000,"fecha":"2026-06-23T11:58:42.552Z"},{"cartera_id":"f2c0a224-0498-4192-85d3-f21e9ba5433c","venta_id":"37c3b9c1-7762-4c98-9c60-73488df6f1bf","monto":1500000,"fecha":"2026-06-22T22:47:16.777Z"},{"cartera_id":"bdff5456-02c3-4e42-aa5c-5295fcc8dfcd","venta_id":"8b9b8573-85b4-4232-8923-6ccc682d7183","monto":3000000,"fecha":"2026-06-23T11:56:18.857Z"},{"cartera_id":"2d4acf65-a0d0-40aa-a576-e11a0b39d248","venta_id":"e4a3190f-4147-4d15-a763-7b14403c054e","monto":1100000,"fecha":"2026-07-01T23:50:37.341Z"},{"cartera_id":"770d3fae-f8b7-4b44-ab61-2e1a1aa9c1bd","venta_id":"0beaf1b7-e5dd-4ba4-a491-23cd57157441","monto":1100000,"fecha":"2026-06-27T22:06:59.164Z"},{"cartera_id":"bf23317b-9ace-48cf-9afa-36fa111f513f","venta_id":"bb77aa83-b828-4342-9d7e-43fa3cc4fdcb","monto":28000,"fecha":"2026-06-06T01:45:38.059Z"},{"cartera_id":"7ebadab7-6b88-4652-b4b1-f1574c50343b","venta_id":"a0c89279-97a1-44e8-a1bf-3a2316c2279b","monto":28000,"fecha":"2026-06-06T01:47:27.384Z"},{"cartera_id":"2739b564-f206-43f4-bed0-30ac4e216e13","venta_id":"209a1a92-22f3-4b28-b5b4-7e9c418c3563","monto":400000,"fecha":"2026-06-07T00:17:28.360Z"},{"cartera_id":"df33472e-e389-4f1c-9fda-6f7a9199fe2d","venta_id":"955c14e3-bb66-497f-8815-cf2fcc374d7a","monto":250000,"fecha":"2026-06-11T13:55:40.931Z"},{"cartera_id":"177af9a0-8b88-444a-9d04-73c853ae7a9a","venta_id":"a9b126c4-5eee-4719-9e3a-758956c30c81","monto":250000,"fecha":"2026-06-16T17:44:10.762Z"},{"cartera_id":"ee87bb8b-727a-4d9c-8df1-db2d2a807d7f","venta_id":"e57719d4-2489-40b6-a14f-349d52dc3840","monto":350000,"fecha":"2026-06-16T17:46:53.588Z"},{"cartera_id":"1cc0d5d7-0249-4605-95d7-c5c8095b34ae","venta_id":"ecd3af63-4a22-4b2a-a913-45e36e8c0719","monto":1800000,"fecha":"2026-06-17T17:01:12.547Z"},{"cartera_id":"1287d14a-d730-48c0-a5f5-f85c87d4d0dc","venta_id":"8c363647-3bc4-48e9-be66-275ece5e6878","monto":160000,"fecha":"2026-06-17T18:01:55.339Z"},{"cartera_id":"c4020dea-ff34-477e-a1a1-5e712f2697bd","venta_id":"ba4ec5c2-471c-4bfa-9564-ad375de3e8c7","monto":220000,"fecha":"2026-06-18T16:51:07.063Z"},{"cartera_id":"dccab523-f578-4db7-8d4d-0b6efbee2e14","venta_id":"8c2eb405-2148-4d89-9cc4-1a4d5f206929","monto":300000,"fecha":"2026-06-19T22:30:28.291Z"},{"cartera_id":"4530860c-b00a-44e0-b9ce-f40291b8ef16","venta_id":"53f01172-df19-45ea-9b66-481f4211bfda","monto":700000,"fecha":"2026-06-25T19:41:35.065Z"},{"cartera_id":"99b460db-42ad-4682-aff8-abd83229dea3","venta_id":"1d0e5197-9297-4002-959b-e3b5d2395f97","monto":500000,"fecha":"2026-06-27T18:34:04.871Z"},{"cartera_id":"06d90a69-9509-4aa1-8b21-795a50339916","venta_id":"18bd3164-c849-4800-8491-2195b2b39cd2","monto":542000,"fecha":"2026-07-02T20:40:47.771Z"},{"cartera_id":"e807755f-67f9-4409-a35e-a1408ba0127b","venta_id":"a446044f-5ac8-4dfb-a60e-007d7d024df2","monto":542000,"fecha":"2026-07-02T20:43:37.864Z"},{"cartera_id":"852b4536-d412-4c65-963d-d2ef06072173","venta_id":"2ebcf30a-7c31-4ee3-87a6-1d4da25cf655","monto":1850000,"fecha":"2026-07-03T13:17:17.807Z"},{"cartera_id":"4753b6fb-bbb9-44b9-945f-c89b461126d2","venta_id":"cb614535-cf67-4f1d-bff7-da5f3f1f8e28","monto":500000,"fecha":"2026-07-03T13:01:00.939Z"},{"cartera_id":"a4a36fb5-d731-4f3d-9273-5dfe7d698fa9","venta_id":"7ffbe264-be27-4b34-930e-3d21acda2f66","monto":5000000,"fecha":"2026-07-05T10:58:34.271Z"},{"cartera_id":"dd3977a2-3360-4134-a3b3-9da0bb8b1fd2","venta_id":"e35c2d59-f5f6-4d53-8131-936f5d224227","monto":1700000,"fecha":"2026-07-07T12:11:06.634Z"},{"cartera_id":"8bd3b88a-3ce1-494d-8865-4085454e4b74","venta_id":"33184b58-f355-4f5c-a7a2-fb86b3633689","monto":1100000,"fecha":"2026-07-07T12:16:15.968Z"},{"cartera_id":"9839a7cc-cdfe-4a74-a982-4a100dd0bf49","venta_id":"278c632e-ff2b-4809-9cb7-81ceab1bea82","monto":300000,"fecha":"2026-07-07T12:18:17.793Z"},{"cartera_id":"bbc9aacc-c50d-4900-a5ce-e44fc0ec883e","venta_id":"379f6bc8-9eee-4087-b7f1-69553a386bfe","monto":500000,"fecha":"2026-07-07T12:23:01.820Z"},{"cartera_id":"42ab7b9a-525e-47d6-9290-9cb3976253ce","venta_id":"6685e45f-4083-41fd-a2e6-b214d5a1496e","monto":850000,"fecha":"2026-07-07T17:03:38.315Z"},{"cartera_id":"0ec1a581-5705-44d6-ab0a-1cf8d2369d1f","venta_id":"ff1fac62-d881-46dc-9d94-848c10f2888d","monto":250000,"fecha":"2026-07-15T19:36:18.266Z"},{"cartera_id":"0ec1a581-5705-44d6-ab0a-1cf8d2369d1f","venta_id":"ff1fac62-d881-46dc-9d94-848c10f2888d","monto":207000,"fecha":"2026-07-18T17:44:11.631Z"},{"cartera_id":"d1c2eab8-f53a-4c15-a254-65e3a0495ba7","venta_id":"ffe9a46a-6b75-43ac-9317-cab147669bcb","monto":1209724,"fecha":"2026-07-18T22:01:23.455Z"},{"cartera_id":"d1c2eab8-f53a-4c15-a254-65e3a0495ba7","venta_id":"ffe9a46a-6b75-43ac-9317-cab147669bcb","monto":1000000,"fecha":"2026-07-22T00:51:20.807Z"},{"cartera_id":"974dc4f2-2577-479d-b28f-e9f119c4d231","venta_id":"1d15c02c-193a-4a9e-95d4-53110a6d1f81","monto":1683000,"fecha":"2026-07-19T18:15:33.525Z"},{"cartera_id":"974dc4f2-2577-479d-b28f-e9f119c4d231","venta_id":"1d15c02c-193a-4a9e-95d4-53110a6d1f81","monto":800000,"fecha":"2026-07-22T00:51:41.536Z"},{"cartera_id":"974dc4f2-2577-479d-b28f-e9f119c4d231","venta_id":"1d15c02c-193a-4a9e-95d4-53110a6d1f81","monto":200000,"fecha":"2026-07-23T22:15:42.842Z"},{"cartera_id":"2e9e826f-9518-4425-b8c6-eac04b5d97a4","venta_id":"7644d53b-5d18-4377-b4ee-3024dbde21ad","monto":480000,"fecha":"2026-08-05T02:43:23.054Z"},{"cartera_id":"4b6ebb2a-5aac-4be1-85c4-61afe8cd9acf","venta_id":"f5995ed6-f8c1-4a92-9fae-adcdc747eaba","monto":500000,"fecha":"2026-07-31T01:09:37.244Z"},{"cartera_id":"4b6ebb2a-5aac-4be1-85c4-61afe8cd9acf","venta_id":"f5995ed6-f8c1-4a92-9fae-adcdc747eaba","monto":313600,"fecha":"2026-08-05T02:36:27.614Z"},{"cartera_id":"2bbbb4d4-1c20-493c-8fab-824948b4bc3e","venta_id":"afa1797f-9f1c-4ba9-a452-a23d1045bdd8","monto":250000,"fecha":"2026-07-15T19:32:27.453Z"}]'::jsonb;
  r record;
  n integer;
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- 1) Caja cerrada
  IF EXISTS (SELECT 1 FROM caja_sesiones WHERE id_licencia = 'lacava' AND (estado <> 'cerrada' OR fecha_cierre IS NULL)) THEN
    RAISE EXCEPTION 'Hay una caja ABIERTA. Cierra la caja y vuelve a ejecutar este script. No se modificó nada.';
  END IF;

  -- 2) Una sola vez
  IF EXISTS (SELECT 1 FROM cartera_abonos WHERE registrado_por = c_tag) THEN
    RAISE EXCEPTION 'Esta recuperación YA se ejecutó antes (existen abonos con la marca %). No se modificó nada.', c_tag;
  END IF;

  -- 3) Bloquear y verificar cada cartera contra la foto
  PERFORM 1 FROM cartera
   WHERE id IN (SELECT (e->>'cartera_id')::uuid FROM jsonb_array_elements(c_esperado) e)
   ORDER BY id FOR UPDATE;
  FOR r IN
    SELECT x.*, c.id AS c_id, c.id_licencia, c.venta_id AS c_venta, c.total AS c_total, c.saldo_pendiente AS c_saldo,
           c.estado_cartera AS c_estado, c.fecha_creacion AS c_fc, v.abono AS v_abono, v.total AS v_total, v.estado AS v_estado,
           (SELECT count(*) FROM cartera_abonos a WHERE a.cartera_id = x.cartera_id) AS a_n,
           (SELECT COALESCE(sum(monto), 0) FROM cartera_abonos a WHERE a.cartera_id = x.cartera_id) AS a_suma
      FROM jsonb_to_recordset(c_esperado) AS x(cartera_id uuid, venta_id uuid, numero int, total numeric, abono_venta numeric,
           saldo numeric, estado text, n_abonos int, suma_abonos numeric, fecha_creacion timestamptz)
      LEFT JOIN cartera c ON c.id = x.cartera_id
      LEFT JOIN ventas v ON v.id = x.venta_id
  LOOP
    IF r.c_id IS NULL OR r.id_licencia <> 'lacava' OR r.c_venta <> r.venta_id OR r.c_total <> r.total
       OR r.c_saldo <> r.saldo OR r.c_estado <> r.estado OR r.a_n <> r.n_abonos OR r.a_suma <> r.suma_abonos
       OR r.v_abono IS DISTINCT FROM r.abono_venta OR r.v_total <> r.total OR r.v_estado <> 'credito'
       OR r.c_fc <> r.fecha_creacion THEN
      RAISE EXCEPTION 'La venta #% cambió desde la foto (saldo %, estado %, abonos %/%). No se modificó nada.',
        r.numero, r.c_saldo, r.c_estado, r.a_n, r.a_suma;
    END IF;
  END LOOP;

  -- 3b) Ningún abono nuevo puede repetir uno existente de la misma cartera (mismo monto y fecha)
  IF EXISTS (SELECT 1 FROM jsonb_to_recordset(c_nuevos) AS x(cartera_id uuid, venta_id uuid, monto numeric, fecha timestamptz)
              JOIN cartera_abonos a ON a.cartera_id = x.cartera_id AND round(a.monto) = round(x.monto)
                                   AND abs(extract(epoch FROM a.fecha - x.fecha)) <= 60) THEN
    RAISE EXCEPTION 'Uno de los abonos a recuperar ya existe en el historial. No se modificó nada.';
  END IF;

  -- 4) Insertar los abonos con evidencia
  INSERT INTO cartera_abonos (id_licencia, cartera_id, venta_id, monto, fecha, registrado_por, medio_pago)
  SELECT 'lacava', x.cartera_id, x.venta_id, x.monto, x.fecha, c_tag, NULL
    FROM jsonb_to_recordset(c_nuevos) AS x(cartera_id uuid, venta_id uuid, monto numeric, fecha timestamptz);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 38 THEN RAISE EXCEPTION 'Se esperaban 38 abonos insertados y hubo %. No se modificó nada.', n; END IF;

  -- 5) Dejar las carteras en paz y salvo (solo si siguen exactamente como en la foto)
  UPDATE cartera c SET saldo_pendiente = 0, estado_cartera = 'pagada'
    FROM jsonb_to_recordset(c_esperado) AS x(cartera_id uuid, saldo numeric, estado text)
   WHERE c.id = x.cartera_id AND c.saldo_pendiente = x.saldo AND c.estado_cartera = x.estado;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 33 THEN RAISE EXCEPTION 'Se esperaban 33 carteras actualizadas y hubo %. No se modificó nada.', n; END IF;

  -- 6) Verificación final cuenta por cuenta
  FOR r IN
    SELECT x.numero, c.total, c.saldo_pendiente, c.estado_cartera,
           (SELECT COALESCE(sum(monto), 0) FROM cartera_abonos a WHERE a.cartera_id = c.id) AS suma,
           EXISTS (SELECT 1 FROM cartera_abonos a WHERE a.cartera_id = c.id AND round(a.monto) = round(x.abono_venta)
                     AND abs(extract(epoch FROM a.fecha - c.fecha_creacion)) <= 60) AS espejo
      FROM jsonb_to_recordset(c_esperado) AS x(cartera_id uuid, numero int, abono_venta numeric)
      JOIN cartera c ON c.id = x.cartera_id
  LOOP
    IF abs(r.suma - r.total) > 0.5 OR r.saldo_pendiente <> 0 OR r.estado_cartera <> 'pagada' OR NOT r.espejo THEN
      RAISE EXCEPTION 'Verificación final fallida en la venta #% (abonos %, total %, saldo %, estado %, abono inicial reconocible %). No se modificó nada.',
        r.numero, r.suma, r.total, r.saldo_pendiente, r.estado_cartera, r.espejo;
    END IF;
  END LOOP;

  RAISE NOTICE 'Recuperación completada: 33 carteras en paz y salvo, 38 abonos del respaldo registrados.';
END
$recuperacion$;

-- Resumen (solo lectura) para confirmar el resultado
SELECT 'abonos recuperados' AS dato, count(*)::text || ' filas / $' || to_char(COALESCE(sum(monto), 0), 'FM999G999G999') AS valor
  FROM cartera_abonos WHERE registrado_por = 'recuperacion_respaldo_2026-08-11'
UNION ALL
SELECT 'carteras recuperadas en paz y salvo', count(*)::text
  FROM cartera WHERE estado_cartera = 'pagada' AND saldo_pendiente = 0
   AND id IN (SELECT (e->>'cartera_id')::uuid FROM jsonb_array_elements('[{"cartera_id":"2fcbdde5-ae14-4345-9302-2cf097e64e33"},{"cartera_id":"f2c0a224-0498-4192-85d3-f21e9ba5433c"},{"cartera_id":"bdff5456-02c3-4e42-aa5c-5295fcc8dfcd"},{"cartera_id":"2d4acf65-a0d0-40aa-a576-e11a0b39d248"},{"cartera_id":"770d3fae-f8b7-4b44-ab61-2e1a1aa9c1bd"},{"cartera_id":"bf23317b-9ace-48cf-9afa-36fa111f513f"},{"cartera_id":"7ebadab7-6b88-4652-b4b1-f1574c50343b"},{"cartera_id":"2739b564-f206-43f4-bed0-30ac4e216e13"},{"cartera_id":"df33472e-e389-4f1c-9fda-6f7a9199fe2d"},{"cartera_id":"177af9a0-8b88-444a-9d04-73c853ae7a9a"},{"cartera_id":"ee87bb8b-727a-4d9c-8df1-db2d2a807d7f"},{"cartera_id":"1cc0d5d7-0249-4605-95d7-c5c8095b34ae"},{"cartera_id":"1287d14a-d730-48c0-a5f5-f85c87d4d0dc"},{"cartera_id":"c4020dea-ff34-477e-a1a1-5e712f2697bd"},{"cartera_id":"dccab523-f578-4db7-8d4d-0b6efbee2e14"},{"cartera_id":"4530860c-b00a-44e0-b9ce-f40291b8ef16"},{"cartera_id":"99b460db-42ad-4682-aff8-abd83229dea3"},{"cartera_id":"06d90a69-9509-4aa1-8b21-795a50339916"},{"cartera_id":"e807755f-67f9-4409-a35e-a1408ba0127b"},{"cartera_id":"852b4536-d412-4c65-963d-d2ef06072173"},{"cartera_id":"4753b6fb-bbb9-44b9-945f-c89b461126d2"},{"cartera_id":"a4a36fb5-d731-4f3d-9273-5dfe7d698fa9"},{"cartera_id":"dd3977a2-3360-4134-a3b3-9da0bb8b1fd2"},{"cartera_id":"8bd3b88a-3ce1-494d-8865-4085454e4b74"},{"cartera_id":"9839a7cc-cdfe-4a74-a982-4a100dd0bf49"},{"cartera_id":"bbc9aacc-c50d-4900-a5ce-e44fc0ec883e"},{"cartera_id":"42ab7b9a-525e-47d6-9290-9cb3976253ce"},{"cartera_id":"0ec1a581-5705-44d6-ab0a-1cf8d2369d1f"},{"cartera_id":"d1c2eab8-f53a-4c15-a254-65e3a0495ba7"},{"cartera_id":"974dc4f2-2577-479d-b28f-e9f119c4d231"},{"cartera_id":"2e9e826f-9518-4425-b8c6-eac04b5d97a4"},{"cartera_id":"4b6ebb2a-5aac-4be1-85c4-61afe8cd9acf"},{"cartera_id":"2bbbb4d4-1c20-493c-8fab-824948b4bc3e"}]'::jsonb) e)
UNION ALL
SELECT 'cartera total: activas / pagadas', (SELECT count(*) FROM cartera WHERE estado_cartera = 'activa')::text || ' / ' ||
       (SELECT count(*) FROM cartera WHERE estado_cartera = 'pagada')::text
UNION ALL
SELECT 'saldo pendiente total', '$' || to_char((SELECT COALESCE(sum(saldo_pendiente), 0) FROM cartera), 'FM999G999G999');
