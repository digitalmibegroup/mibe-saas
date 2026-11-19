-- Solo lectura. Devuelve UNA fila: INSTALADO / NO_INSTALADO y, si esta instalado, cuantos productos hay en total y cuantos ocultos.
SELECT CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                          WHERE table_schema = 'public' AND table_name = 'inventario' AND column_name = 'oculto'
                            AND data_type = 'boolean' AND is_nullable = 'NO' AND column_default = 'false')
            THEN 'INSTALADO' ELSE 'NO_INSTALADO' END AS estado_oculto_inventario,
       (SELECT count(*) FROM public.inventario) AS productos_total,
       CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'inventario' AND column_name = 'oculto')
            THEN (SELECT count(*) FROM public.inventario WHERE to_jsonb(inventario.*) ->> 'oculto' = 'true') END AS productos_ocultos;
