# Ocultar y recuperar productos en Inventario

Estado: implementado y probado en local; **sin commit, push ni publicación**. El SQL de abajo **no está aplicado** en ningún Supabase.
Parte del `main` publicado con el aviso de actualización (`38a3839`).

## Qué hace el usuario
- En la tabla de Inventario, los productos **sin existencias en ninguna ubicación** muestran el botón **Ocultar** (los que tienen stock o unidades sueltas no lo muestran).
- Un producto oculto **deja de aparecer en la lista habitual** y **no cuenta** en «Total productos», «Agotados» ni en las alertas de Inventario.
- El filtro **Ocultos (N)** (junto a «Stock bajo» y «Agotados») muestra solo los ocultos, cada uno con **Volver a mostrar**.
- La marca persiste al recargar y entre dispositivos (vive en la base de datos).
- Si un producto oculto **recibe existencias**, **reaparece solo**. Ver «Marca almacenada y visibilidad efectiva» abajo: la limpieza de la marca es de mejor esfuerzo.

## Cómo se calcula «existencias totales en cero»
`inventario.stock = 0` **y** `inventario.uds_sueltas = 0` **y** ninguna fila de `inventario_bodega` con `stock` o `uds_sueltas` distintos de cero.
(En este sistema `stock` cuenta presentaciones —cajas, six-pack— y `uds_sueltas` las unidades sueltas; la bodega secundaria es otra tabla.
Un valor negativo cuenta como «hay existencias»: nunca se oculta un descuadre.)
- Al **ocultar** se relee de Supabase el producto y las filas de su bodega (no se confía en el array local). Si no se puede leer, no se oculta.
- La escritura es un `PATCH` **condicionado** a `stock=0` y `uds_sueltas=0` (mismo principio que `eliminarProducto`): si cambiaron entre la lectura y la escritura no se actualiza nada.
- Al **mostrar** se usa una regla de visualización: un producto está oculto solo si tiene la marca **y** sigue sin existencias. Si no se pudo leer la bodega, se muestra (ante la duda, visible).

## Marca almacenada y visibilidad efectiva
Son dos cosas distintas:
- **Marca almacenada** = `inventario.oculto` (lo que guarda la base).
- **Visibilidad efectiva** = oculto en pantalla **solo si** la marca está puesta **y** el producto sigue sin existencias (principal, sueltas y bodega). Se calcula al mostrar, no se guarda.
Por eso un producto con marca pero con stock **se ve** (mientras tenga stock). Lo que la visibilidad efectiva no puede garantizar solo es que la marca desaparezca; para eso hay una **limpieza** (`PATCH oculto=false`) de mejor esfuerzo:
- **Cuándo se limpia:** en el momento de recibir existencias —enganchada en `ajustarStockAtomicoSB`, el CAS por el que entra todo el stock del inventario principal: Entrada, Ajuste, compra recibida, devoluciones— y, como respaldo, al renderizar Inventario o al volver a la pestaña Principal (cubre bodega y otros dispositivos).
- **Fallos:** una sola petición a la vez por producto (`_limpiando` se libera siempre, con éxito o fallo) y tras un fallo se reintenta como pronto a los 5 s, en la siguiente recepción, render o recarga.
- **Limitación 1 (no se promete limpieza permanente):** si la limpieza **falla** al recibir (sin red) y el producto **se agota antes de que ningún render o recepción posterior la reintente**, la marca queda guardada y el producto **vuelve a estar oculto**: se ve únicamente mientras tiene stock. Se corrige solo cuando vuelve a recibir existencias o se abre Inventario con stock.
- **Limitación 2:** una entrada que no pase por `ajustarStockAtomicoSB` (la escritura directa de `inventario.stock` que devuelve stock en un flujo antiguo de ventas, y las entradas en la **bodega**) no limpia en el momento; la limpia el siguiente render de Inventario/Principal. Si el producto recibe en la bodega y sale de ella antes de eso, queda con marca y vuelve a estar oculto.
- **Carrera con una entrada en la bodega al ocultar:** el `PATCH` condicionado solo puede mirar el inventario principal (la bodega es otra tabla). Tras escribir la marca se vuelve a leer la bodega: si llegó una entrada entre la primera lectura y la escritura, el producto **sigue visible** y la marca se limpia. Si la entrada llega **después** de esa segunda lectura, la marca queda guardada y la pantalla sigue ocultándolo hasta el siguiente refresco (entrar a Inventario o volver a Principal), que lo muestra y limpia. Cerrar del todo estas ventanas exigiría una condición en la base de datos (trigger o función que mire las dos tablas a la vez): **no se agregó**; se presenta aquí como opción solo si Michel considera que la ventana importa.

## Qué cambia en la base de datos (único cambio)
`INVENTARIO_OCULTAR_PRODUCTOS.sql`: `ALTER TABLE public.inventario ADD COLUMN IF NOT EXISTS oculto boolean NOT NULL DEFAULT false;`
Idempotente, no reescribe datos, no cambia índices ni políticas (RLS). Reversión: `INVENTARIO_OCULTAR_PRODUCTOS_REVERTIR.sql`. Comprobación de solo lectura: `INVENTARIO_OCULTAR_PRODUCTOS_VERIFICAR.sql`.
**Sin la columna** la aplicación sigue igual: nada aparece oculto y «Ocultar» avisa «Falta activar esta función en la base de datos». Así se puede publicar el código antes o después del SQL sin romper nada.

### ¿Por qué no se reutilizó nada existente?
- `catalogo_producto_oculto` es la visibilidad del **catálogo virtual** (otra función, otra pantalla): reutilizarla acoplaría «ocultar en Inventario» con «ocultar en la tienda» y tendría efectos fuera de Inventario.
- `producto_presentaciones.activo` es de presentaciones de costo, no de productos.
- No existe un filtro temporal «Ocultar sin stock»; el filtro «Agotados» *muestra* solo los agotados (no los oculta), y sigue como estaba.
- `inventario` no tenía ningún campo de activo/oculto/archivado.

## Relación con los demás módulos (revisada antes de cambiar nada; no se modifica ninguno)
| Módulo | Qué usa | Efecto |
|---|---|---|
| **POS** | `INVENTARIO` completo (`renderPOS`) | Ninguno: el producto sigue en el POS (con 0 existencias, como hoy). |
| **Compras** | `INVENTARIO` completo (selectores de producto; «Crear compra desde Inventario») | Ninguno: se puede comprar un producto oculto; al **recibir** la compra reaparece en Inventario. |
| **Cotizaciones** | `INVENTARIO` completo (cuadrícula de productos) | Ninguno. |
| **Catálogo virtual** | `catalogo_producto_oculto` y `inventario` (`select=*`) | Ninguno: marca propia e independiente; la columna nueva se ignora. |
| **Bodegas / Traslados** | `inventario_bodega`, `INVENTARIO` como maestro | Ninguno: la vista de bodega solo lista productos presentes en la bodega. Un traslado a la bodega hace reaparecer al producto en Principal. |
| **Entrada / Salida / Ajuste** | selector con `INVENTARIO` completo | Ninguno: se puede dar entrada a un producto oculto (y reaparece). |
| **Historial** (ventas, compras, traslados, presentaciones) | — | No se toca: «Ocultar» solo escribe `inventario.oculto`. Eliminar (🗑) sigue siendo otra acción, con sus propias reglas. |
Solo Inventario (tabla, estadísticas, alertas) usa la regla de visibilidad; una prueba revisa el código para que siga así.

## Decisiones pendientes para Michel
1. **Aplicar el SQL** (primero en staging) antes de publicar el código; mientras no esté, la función no se activa.
2. ¿Los productos ocultos deben seguir **apareciendo en el POS/Cotizaciones**? Hoy sí (se pidió solo la presentación de Inventario).
3. **Reaparición:** lo implementado muestra el producto **mientras tiene stock** y limpia la marca al recibir (mejor esfuerzo, ver «Marca almacenada y visibilidad efectiva»). Si la limpieza falla y se agota, **vuelve a estar oculto**. ¿Basta con eso, o se quiere una garantía en la base (trigger/función) que limpie la marca cuando entren existencias?
4. La vista de bodega no tiene «Ocultar» (no se pidió).

## Pruebas
`tests/inventario-ocultar/` (ver `LEEME.md`): 10 pruebas en Chrome real (escritorio y móvil, base simulada con estado) y 5 del SQL en un PostgreSQL local temporal.

## Registro del despliegue en producción (2026-11-19)
- **Pausa de operaciones** acordada con Michel (sin ventas, caja cerrada, sistema sin uso) durante el respaldo y la instalación.
- **Respaldo fresco de producción** (fuera del repositorio): `LaCava-respaldos\respaldo-lacava-20261119-102408\lacava-public-20261119-102408.dump`, SHA-256 `5a3b171e57a9a6f2…6ca9`. Verificado por restauración local en un PostgreSQL desechable sin red: `pg_restore` con 0 errores, 26 tablas y 6.356 filas coincidentes con el manifiesto. (El primer intento falló solo porque el verificador no creaba el rol `cotconv_ejecutor` que usan las políticas del hotfix —los roles no viajan en `pg_dump`—; se añadió ese rol a `VERIFICAR-RESPALDO-RESTAURANDO-LOCAL.ps1` y los datos no cambiaron.)
- **Foto previa y posterior** con `INSTALAR-OCULTAR-INVENTARIO-EN-PRODUCCION.ps1` (guarda invertida: solo acepta la huella de producción `cea2aa59…` y se niega si existe `staging_marca`; fija el SHA-256 de los SQL). Evidencia en `LaCava-evidencia-local\inventario-ocultar-produccion-cea2aa59bd\` (`VERIFICAR-…103118-160.txt`, `INSTALAR-…103253-276.txt`).
- **Se aplicó únicamente `INVENTARIO_OCULTAR_PRODUCTOS.sql`**, en una transacción con `lock_timeout` de 5 s. Resultado: `oculto boolean NOT NULL DEFAULT false`; 111 productos, misma huella de datos; ACL, políticas (`anon_all_inventario`, `cotconv_*`) y permisos iguales. **Permisos de `anon`:** ya tenía acceso completo a la tabla (la política `anon_all_inventario` que usa producción); la columna los hereda (`SELECT=true,UPDATE=true`, igual que la tabla) y no se concedió nada. 0 productos ocultos. No se ocultó ni modificó ningún producto real.
- **Ensayo previo en staging `ca10112ba2`** (2026-11-19): ver `PLAN_ENSAYO_INVENTARIO_OCULTAR_EN_STAGING.md`; los productos `ens-ocu-*` y la columna se conservan allí.

## Limitación aceptada: limpieza de la marca
La **visibilidad efectiva** (el producto se oculta solo si tiene la marca *y* no tiene existencias en ninguna ubicación) es siempre correcta al mostrar; la **limpieza de la marca almacenada** `inventario.oculto` al recibir existencias es de **mejor esfuerzo** (una petición `PATCH oculto=false`, enganchada en `ajustarStockAtomicoSB` y como respaldo al renderizar Inventario). Se acepta que:
1. Si esa limpieza **falla** (p. ej. sin red) y el producto **se agota** antes de que algún render o recepción posterior la reintente, la marca queda guardada y el producto **vuelve a estar oculto**: se vio solo mientras tuvo stock.
2. Entradas que no pasan por `ajustarStockAtomicoSB` (la escritura directa que devuelve stock en un flujo antiguo de ventas y las entradas en la **bodega**) no limpian en el momento; las limpia el siguiente render de Inventario o de la pestaña Principal.
3. Una entrada en la bodega que llega **después** de la comprobación posterior de «Ocultar» deja la marca guardada y la pantalla lo oculta hasta el siguiente refresco.
No se agregaron triggers ni funciones en la base. Una garantía en la base (trigger o función que mire inventario y bodega a la vez) queda como mejora opcional, solo si Michel considera que estas ventanas importan.
