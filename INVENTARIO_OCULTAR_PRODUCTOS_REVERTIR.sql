-- Revierte INVENTARIO_OCULTAR_PRODUCTOS.sql: elimina la columna public.inventario.oculto.
-- Efecto: todos los productos vuelven a la lista habitual de Inventario. No toca ningun otro dato.
-- No se aplica automaticamente: ejecutar solo con autorizacion expresa.
ALTER TABLE public.inventario DROP COLUMN IF EXISTS oculto;
