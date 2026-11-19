-- ============================================================================
-- INVENTARIO: ocultar y recuperar productos (solo presentacion del modulo Inventario)
-- ============================================================================
-- Agrega UNA columna a public.inventario. Es el unico cambio de base de datos.
--   oculto boolean NOT NULL DEFAULT false
-- - No toca datos existentes: todas las filas quedan con oculto = false (el valor por defecto se aplica sin reescribir la tabla en PostgreSQL 11+).
-- - No cambia indices, claves, politicas (RLS) ni permisos: las politicas existentes de inventario (p. ej. anon_all_inventario) ya cubren la columna nueva.
-- - Es idempotente: se puede ejecutar mas de una vez.
-- - No se aplica automaticamente. Ejecutarlo en STAGING primero y despues en produccion, SOLO con autorizacion expresa.
-- - Sin la columna la aplicacion sigue funcionando igual: nada aparece oculto y la accion "Ocultar" avisa "Falta activar esta funcion en la base de datos".
-- Reversion: INVENTARIO_OCULTAR_PRODUCTOS_REVERTIR.sql. Comprobacion: INVENTARIO_OCULTAR_PRODUCTOS_VERIFICAR.sql.
-- ============================================================================
ALTER TABLE public.inventario ADD COLUMN IF NOT EXISTS oculto boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.inventario.oculto IS
  'Presentacion del modulo Inventario: true = el usuario oculto el producto de la lista habitual (solo permitido sin existencias en ninguna ubicacion). No afecta POS, compras, cotizaciones, catalogo ni bodegas.';
