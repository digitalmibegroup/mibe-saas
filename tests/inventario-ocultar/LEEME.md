# Pruebas de «Ocultar / Volver a mostrar» productos en Inventario

Sin dependencias (Node, Chrome o Edge, y el PostgreSQL portable de las pruebas del hotfix). Desde la raíz del repositorio:

```bash
node --test tests/inventario-ocultar/
```

- `ocultar-productos.test.cjs` (10, navegador real, escritorio 1366×768 y móvil 390×844): ocultar y volver a mostrar con una **base simulada con estado** (`inventario` e
  `inventario_bodega`, filtros `eq.` y `PATCH` condicionado como PostgREST; reutiliza `tests/aviso-actualizacion/cdp.cjs`, al que se añadió el gancho `manejador`).
  Cubre: solo con existencias totales en cero (stock, **unidades sueltas** y **bodega**); una sola escritura condicionada que solo toca `oculto`; vista Ocultos; persistencia
  entre **recargas y dispositivos**; **recibir existencias** (entrada real de la aplicación, unidades sueltas, bodega) → reaparece y se limpia la marca; **rechazo** cuando hay
  existencias (lectura real, carrera entre lectura y escritura, bodega ilegible); fallos (guardado, columna inexistente); alcance (POS, Cotizaciones, Entrada siguen viendo el
  producto; revisión de código); móvil; **limpieza de la marca**: fallo y reintento (`_limpiando` se libera, sin peticiones simultáneas), recibir y agotar sin abrir Inventario (con y sin fallo de la limpieza) y la carrera de una entrada en bodega entre la lectura y el PATCH de ocultar.
- `sql-oculto.test.cjs` (5, PostgreSQL local temporal, sin red): `INVENTARIO_OCULTAR_PRODUCTOS.sql` agrega solo la columna, no toca datos, es idempotente, funciona con la
  política de `anon`; la verificación y la reversión se comportan como se documenta.

Variables: `LACAVA_NAVEGADOR`, `LACAVA_EVIDENCIA` (capturas; por defecto `~/LaCava-evidencia-local/inventario-ocultar`), `LACAVA_PG_BIN`. Antes de probar el navegador, `deploy/` debe estar sellado
(`node scripts/sellar-version.cjs`).

## Preparación del ensayo en staging (sin conectar; ver `PLAN_ENSAYO_INVENTARIO_OCULTAR_EN_STAGING.md`)
- `ensayo-staging/ensayo-staging.test.cjs` (6, local): la foto de solo lectura en un PostgreSQL temporal (instalar y revertir solo cambian la columna), la lista blanca del servidor local de ensayo y el guion de datos ficticios contra un staging simulado en memoria.
- `ensayo-staging/servidor-ensayo-inventario.cjs` y `ensayo-staging-inventario-semilla.cjs`: se usan **solo** con autorización de Michel contra staging `ca10112ba2`.
