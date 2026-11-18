# Hotfix de cotizaciones — conversión atómica, integridad del registro (informe para auditoría)

**Fecha:** 17-nov-2026.

**Estado:**
- Desarrollado y probado solo en local: PostgreSQL temporal real con datos ficticios.
- No se aplicó SQL en staging ni en producción.
- No hay commit, push ni publicación.
- v5–v8 sigue pausado y aislado: no se tocó la copia de integración (blob `a9e5245bbfbe`) ni el borrador de Michel (blob `7623dba99850`).

## Respuesta a los cuatro hallazgos del auditor

| Hallazgo | Corrección | Cómo se prueba |
|---|---|---|
| `anon`/`authenticated` podían insertar en `cotizacion_conversiones` (`WITH CHECK(true)`) | Ni anon ni authenticated tienen **ningún privilegio** sobre el registro (ni SELECT). Solo lo escribe la función, que ahora es `SECURITY DEFINER` con dueño de privilegios mínimos (ver abajo) | Como `anon` y como `authenticated`: INSERT falso, SELECT, UPDATE, DELETE y TRUNCATE dan `42501` y no cambia ningún dato |
| El reintento devolvía un resultado guardado sin verificar la conversión | El registro solo dice que la operación existió. La respuesta se arma con el **estado real**: la venta existe y es de esa cotización, la cotización sigue vinculada a ella y, si es crédito, existe la cartera. Si algo no coincide, error sin tocar nada | Fila falsa "perfecta" insertada por un administrador: el reintento da `CV022` o `CV023`, nunca una confirmación. Desvincular la cotización o borrar la cartera → `CV023` |
| `ON DELETE CASCADE` borraba el registro al eliminar la venta | El registro **no tiene claves foráneas** (ni a ventas ni a cotizaciones). Además es de solo añadir: un disparador impide UPDATE, DELETE y TRUNCATE incluso al administrador | Se elimina una venta por los pasos reales de `eliminarVenta()` (como anon): el registro sigue; el reintento da `CV022`, sin recrear la venta ni volver a descontar |
| La reversión eliminaba toda la evidencia | Ver "Reversión" más abajo: sin operaciones retira todo; con operaciones **conserva la tabla** y su protección | Reversión antes de operar, después de operar y con venta eliminada; reinstalación reutiliza el registro |

## Diseño de permisos y ejecución

- **`SECURITY DEFINER` con un dueño sin privilegios extra.** La función ya no corre con los privilegios de quien la llama (así podía escribir el registro sin abrirlo a anon), pero tampoco con los de `postgres`: su dueño es un rol nuevo `cotconv_ejecutor`:
  - sin login, sin superusuario, sin `BYPASSRLS`, sin `CREATEROLE` ni `CREATEDB`;
  - con **solo estos privilegios**, sin DELETE ni TRUNCATE en nada:

| Tabla | Privilegios de `cotconv_ejecutor` |
|---|---|
| `ventas`, `detalle_ventas`, `cartera`, `cartera_abonos` | SELECT, INSERT |
| `cotizacion_conversiones` | SELECT, INSERT (sin UPDATE ni DELETE) |
| `cotizaciones` | SELECT + UPDATE de `estado`, `venta_id`, `updated_at`, `cliente_nombre`, `cliente_whatsapp` |
| `inventario` | SELECT + UPDATE de `stock` y `uds_sueltas` |
| `clientes_frecuentes` | SELECT (no escribe) |
| secuencia `ventas_numero_venta_seq` | USAGE |

- **RLS:** las tablas la tienen activa, así que se crean políticas **solo para este rol y por comando** (15 en total). Las políticas de anon no cambian: sigue habiendo 7.
- **`search_path = public, pg_temp`** en las funciones, y todos los objetos se citan con esquema `public`.
- **EXECUTE** revocado a PUBLIC, anon y authenticated, y concedido solo a anon y authenticated sobre **estas dos funciones**. No se toca ninguna otra función ni tabla.
- **Licencia:** toda lectura y escritura filtra por `p_id_licencia`. Una cotización, un producto o un cliente de otra licencia se rechazan.
- **Un script de verificación de solo lectura** (`HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql`) muestra funciones, dueño, rol, privilegios por tabla, columnas escribibles, RLS, políticas y disparadores, y marca cada incumplimiento como `ERROR|…`. El propio instalador ejecuta las mismas comprobaciones al final y **deshace toda la instalación** si algo no cumple.

### Límites del acceso anónimo que ya existe en producción

El hotfix no los resuelve ni los empeora; cerrarlos es el trabajo de identidad y licencia (H1), fuera de este alcance:
- La clave anon es pública (va dentro del HTML).
- En producción, las tablas de negocio (`ventas`, `detalle_ventas`, `cotizaciones`, `cartera`, `cartera_abonos`, `clientes_frecuentes`, `inventario`) tienen políticas abiertas a anon. Quien tenga la clave ya puede leerlas y escribirlas directamente, **también fabricar ventas, detalles, cartera o cambiar inventario** sin pasar por la función. Esta corrección no cambia eso.
- `p_id_licencia` lo envía el navegador sin autenticar, igual que hoy `CID`.
- Lo que sí cambia: el **registro de operaciones** ya no está abierto, y las dos funciones nuevas son lo único que lo toca. Cualquiera con la clave puede llamar a la función (es su propósito), pero solo puede hacer lo que la función valida; no obtiene lectura ni escritura directa del registro.
- `cotizacion_conversion_info` (solo lectura) devuelve los ids de venta y fechas de las operaciones de una cotización de esa licencia: datos que anon ya podía leer en `ventas` y `cotizaciones`.
- `service_role` (clave secreta de servidor) se quita del registro con `REVOKE ALL`. Aun así, el disparador de solo añadir lo protege de UPDATE y DELETE.

## Qué devuelve un reintento (definición)

| Situación | Respuesta |
|---|---|
| Misma clave, mismos datos, conversión intacta | `ok`, `repetida: true`, `verificada: true`, con los datos **reales** de la venta; no escribe nada |
| Misma clave con otros datos | `CV020`: la clave ya se usó con otros datos; no se registra nada |
| La venta de esa operación **fue eliminada** | `CV022`: "La operación ya se confirmó antes, pero su venta fue eliminada. No se recreó la venta ni se volvió a descontar inventario." No escribe nada |
| La cotización de esa operación fue eliminada | `CV024`, mismo mensaje con la cotización |
| Registro y estado real no coinciden (cotización desvinculada, falta la cartera de un crédito) | `CV023`: no se modificó nada, revisión manual |
| Una operación **nueva** sobre una cotización liberada tras eliminar la venta | Convierte con su propia clave. La clave antigua sigue dando `CV022`: no se apodera de la venta nueva |

## Reversión (`HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql`)

Siempre retira **la instalación**: las dos funciones, las políticas del rol, sus privilegios y el rol.
- **Registro vacío** (nunca se convirtió nada): elimina también la tabla. Todo queda como antes.
- **Registro con operaciones**: **conserva la tabla**, junto con su protección de solo añadir y sin privilegios para anon. Lo informa con un aviso ("se CONSERVO … N operaciones"). Una reinstalación posterior reutiliza ese registro y los reintentos de operaciones antiguas se verifican.
- Eliminar la evidencia a propósito es una decisión aparte: `DROP TABLE public.cotizacion_conversiones;` después de respaldarla. Este script no lo hace.
- Ventas, carteras, abonos e inventario ya creados se conservan siempre.

**Procedimiento de vuelta atrás, en este orden:**
1. Republicar el frontend anterior (deploy anterior en Netlify). Si no, "Convertir en venta" informa que la conversión segura no está instalada y no registra nada.
2. Ejecutar `HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql` (anotar cuántas operaciones hay).
3. Ejecutar el REVERTIR y leer el aviso.
4. Ejecutar de nuevo el VERIFICAR: esperado `NO_INSTALADO` (y `REGISTRO|operaciones=N` si se conservó).

## Archivos

| Archivo | Contenido |
|---|---|
| `HOTFIX_COT_CONVERSION_ATOMICA.sql` | Instalación (488 líneas, SHA-256 `e07dd6866f56c63c…`). Prechequeo, rol, tabla, privilegios, políticas, funciones, dueño, verificación final; todo en una transacción |
| `HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql` | Reversión por casos (82 líneas, `8ca53b6504bb9727…`) |
| `HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql` | Verificación de solo lectura (54 líneas, `275c56e9cc692952…`) |
| `ENSAYO_COT_CONVERSION_POSTGREST.md` | Procedimiento del ensayo en un proyecto separado |
| `tests/hotfix-cotizaciones/ensayo/ensayo-postgrest.cjs` | Guion del ensayo por PostgREST real (**no ejecutado**) |
| `dashboard_lacava.html`, `deploy/dashboard_lacava.html`, `deploy/index.html` | Frontend (blob `c4e25923e2c7`, los tres idénticos) |
| `deploy/sw.js` | Caché `lacava-v1` → `lacava-v2` |
| `tests/hotfix-cotizaciones/` | 71 pruebas, el esquema mínimo, la RPC de abonos de producción y el adaptador PostgREST local |

El diff del frontend (raíz y `sw.js`) está en el scratchpad: `hotfix-cot/hotfix-cotizaciones.diff` (1206 líneas).

## Cambios en el frontend de esta ronda

- Los errores `CV022`, `CV023` y `CV024` se muestran con el título "Esta operación ya estaba registrada".
- **Verificar** (antes "Verificar y recuperar"; ya no recupera nada) usa la RPC de solo lectura `cotizacion_conversion_info` para distinguir:
  - una cotización convertida cuya venta se eliminó (muestra "venta eliminada, no se recrea ni se descuenta de nuevo");
  - una conversión incompleta de la versión anterior.
  
  En ambos casos solo diagnostica: no repara nada.
- La tarjeta de la cotización, el aviso global y Ventas usan el mismo texto neutro.
- El resto del hotfix (clientes, dirección, empaques, pagos, reintento con la misma clave, bloqueo del borrado de cotizaciones convertidas) no cambia.

## Resultados de pruebas

Todas en local. **71 pruebas, ejecutadas tres veces seguidas: 71/71 las tres veces**, sin fallos ni reintentos.

| Suite | Pruebas |
|---|---|
| Función en PostgreSQL temporal real, como rol anon | 23 |
| **Integridad del registro** (nueva) | 16 |
| Frontend real contra la función (adaptador PostgREST local) | 15 |
| Clientes, plan y pago (base simulada) | 14 |
| Guion del ensayo, ejecutado contra el adaptador local | 3 |

- **PostgreSQL temporal:** versión 17 portable, solo local y datos ficticios. La instalación se prueba con un administrador **sin superusuario** (`CREATEROLE`, dueño de las tablas), como el rol `postgres` de Supabase. Así se ejercitan la creación del rol, la transferencia de propiedad de las funciones y las concesiones.
- **Integridad del registro (16):**
  - INSERT falso, SELECT, UPDATE, DELETE y TRUNCATE directos como **anon** y como **authenticated**: todo `42501`, sin cambios;
  - la conversión real con esa misma clave se procesa como nueva y su reintento se verifica;
  - filas fabricadas por un administrador: `CV022` y `CV023`, sin cambios en negocio;
  - desvincular la cotización o borrar la cartera: `CV023`;
  - la respuesta del reintento sale de los datos reales;
  - **eliminar una venta convertida** por el flujo normal: el registro sobrevive, el reintento da `CV022`, no recrea la venta ni descuenta de nuevo, y anon no puede borrar el registro;
  - liberar la cotización y convertir con una clave nueva: la antigua sigue dando `CV022`;
  - el registro es de solo añadir incluso para el administrador;
  - otra licencia no ve ni usa la evidencia;
  - **reversión antes de operar**, **después de operar** (conserva el registro) y **con una venta ya eliminada**; reinstalación reutiliza el registro;
  - la instalación es todo o nada: un fallo a mitad no deja rol, tabla ni políticas;
  - el prechequeo rechaza una instalación previa o un registro con otra estructura;
  - el VERIFICAR no reporta errores y no cambia nada.
- **Función (23):** se conservan, ya con el diseño `DEFINER`: los cuatro pagos, empaques, 28 rechazos de datos inválidos, concurrencia, reintentos, conflicto de clave y los **7 fallos inyectados** entre pasos (cada uno deja las 8 tablas sin ningún cambio).
- **Frontend (15):** se añaden la operación cuya venta se eliminó y la lectura directa del registro rechazada.
- **Guion del ensayo (3):** el guion completo pasa (28 comprobaciones), se detiene si la función no está instalada, y rechaza la huella de producción sin conectar. Al prepararlo se corrigieron dos errores del propio adaptador local (respuestas JSON multilínea y una columna ambigua en PATCH); no cambió el SQL.
- **Hallazgos corregidos durante el trabajo:**
  - dos pruebas de mi suite fallaban por su propio diseño (semillas que truncaban el registro de solo añadir; el VERIFICAR consultaba una tabla ausente), y las arreglé;
  - el arranque en paralelo de varios PostgreSQL temporales podía chocar en el puerto: ahora reintenta con otro.
- **Regresiones existentes** (`mibe-saas/tests`): `main` e hotfix dan el mismo resultado, 22 pasan y las mismas 7 fallan (misma huella). Son pruebas del borrador de Compras v5.

### Permisos finales (instalación fresca; salida del VERIFICAR)

```
FUNCION|convertir_cotizacion_atomica(...)|definer=true|dueno=cotconv_ejecutor|config=search_path=public, pg_temp|anon_exec=true|auth_exec=true|public_exec=false
FUNCION|cotizacion_conversion_info(text,uuid)|definer=true|dueno=cotconv_ejecutor|config=search_path=public, pg_temp|anon_exec=true|auth_exec=true|public_exec=false
ROL|cotconv_ejecutor|login=false|super=false|bypassrls=false|createrole=false|createdb=false|replic=false
PRIVILEGIO|anon|cotizacion_conversiones|            (ninguno)
PRIVILEGIO|authenticated|cotizacion_conversiones|   (ninguno)
PRIVILEGIO|cotconv_ejecutor|cotizacion_conversiones|SELECT,INSERT
PRIVILEGIO|cotconv_ejecutor|ventas|SELECT,INSERT          (igual en detalle_ventas, cartera y cartera_abonos)
PRIVILEGIO|cotconv_ejecutor|cotizaciones|SELECT           PRIVILEGIO|cotconv_ejecutor|inventario|SELECT
PRIVILEGIO|cotconv_ejecutor|clientes_frecuentes|SELECT
COLUMNAS_ESCRIBIBLES|cotconv_ejecutor|cotizaciones|cliente_nombre,cliente_whatsapp,estado,updated_at,venta_id
COLUMNAS_ESCRIBIBLES|cotconv_ejecutor|inventario|stock,uds_sueltas
RLS|cotizacion_conversiones|activa=true            RESULTADO|INSTALADO   (sin líneas ERROR)
```

La salida completa está en el scratchpad: `hotfix-cot/permisos-finales-local.txt`.

## Ensayo en un proyecto separado (preparado, no ejecutado)

`ENSAYO_COT_CONVERSION_POSTGREST.md` describe los 9 pasos y los criterios de aprobación. En resumen:
1. Proyecto Supabase **nuevo** (no producción ni `ca10112ba2`) con el esquema de producción y datos ficticios o anonimizados.
2. VERIFICAR (`NO_INSTALADO`), instalar, VERIFICAR (`INSTALADO`, sin errores).
3. `node ensayo-postgrest.cjs` por PostgREST real: pide URL y clave anon sin eco, rechaza la huella de producción y exige la frase `ENSAYAR EN PROYECTO SEPARADO`. Escribe solo datos ficticios.
4. Dashboard contra el ensayo: pagos, corte de red con **Reintentar**, dos pestañas.
5. Reversión sin operaciones y con operaciones, y reinstalación.

Cada paso que escribe necesita la autorización de Michel.

## Limitaciones y decisiones que Michel debe aceptar

1. **Cambio de base en producción.** Hay que instalar un rol, una tabla, 15 políticas y dos funciones (con autorización expresa, antes del frontend). Sin ellos, "Convertir en venta" responde que la conversión segura no está instalada y no registra nada.
2. **Lo que solo el ensayo real confirma.** El instalador y sus permisos se probaron con un administrador sin superusuario simulado en un PostgreSQL local, no con el rol real `postgres` de Supabase. Si el ensayo muestra que Supabase no permite crear el rol o transferir la propiedad, el cambio mínimo alternativo sería que el dueño sea `postgres` (privilegios no limitables, solo por el código); eso se decidiría después de ver el resultado.
3. **Acceso anónimo existente** (arriba): no se resuelve; el registro sí queda cerrado.
4. **Cotización "convertida" sin venta** (venta eliminada, o conversión incompleta de la versión anterior): ahora solo se diagnostica; **no hay forma de liberarla desde la aplicación**. La versión publicada hoy sí podía liberarla ("Verificar y recuperar"). Para recuperarla haría falta una función adicional (`liberar`) que solo actúe con evidencia en el registro y sin venta; no está incluida y requiere su propia autorización. Mientras tanto, esa cotización queda bloqueada para editar y convertir, y la liberación manual debe hacerse con revisión.
5. **Conversiones incompletas de la versión anterior:** solo diagnóstico; no se reparan automáticamente. En producción había 0 el 16-nov.
6. **Constantes de puntos** (50 000 y 800) duplicadas en el SQL; si cambian en el dashboard, hay que cambiarlas también en la función.
7. **Números de venta:** un intento fallido consume un número de la secuencia y puede dejar huecos.
8. **Clientes duplicados:** sin índice único en `clientes_frecuentes`, dos dispositivos pueden duplicar una ficha a la vez.
9. **Dirección:** la cotización no guarda copia; se propone la de la ficha actual y se guarda la confirmada en la venta.
10. **Marca de mayorista:** `toggleMayorista` sigue fallando (la columna no existe); queda fuera del alcance.
11. **Alcance de las pruebas:** no se probó contra la PostgREST real, ni contra Postgres de Supabase, staging ni producción.

## Publicación (requiere autorización de Michel)

1. Revisar este informe, los SQL y el diff; aceptar las limitaciones.
2. Hacer el ensayo en el proyecto separado (documento aparte) y revisar sus resultados.
3. Producción: lectura de solo lectura (VERIFICAR `NO_INSTALADO` y `PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql` con `RESULTADO|CONFORME_CON_EXCEPCION_DOCUMENTADA_10`).
   La lectura previa de producción (2026-11-18) encontró **10** cotizaciones `convertida` cuya venta existe y es completada, pero no guarda `ventas.cotizacion_id`
   (conversiones históricas de agosto de 2026, anteriores al enlace inverso). Decisión de Michel: **no se reparan** y el alcance del hotfix no cambia. Con el hotfix siguen
   mostrándose como "Convertida", no se pueden reconvertir (`CV011`) y el intento no modifica ventas, inventario, cartera, abonos ni el registro (ensayo sobre la copia
   local del respaldo: `tests/hotfix-cotizaciones/ensayo/ensayo-copia-respaldo.ps1`). La lista exacta de las 10 está en el procedimiento de producción; cualquier otra anomalía detiene el despliegue.
4. Instalar el SQL en producción y ejecutar el VERIFICAR (`INSTALADO`, sin `ERROR`).
5. Publicar el frontend: rama en la copia aislada, commit de los cuatro archivos del frontend, los tres SQL, el documento de ensayo y `tests/hotfix-cotizaciones/`; integrar en `main` y push (Netlify publica `deploy/`). Confirmar que el sitio sirve el blob `c4e25923e2c7` y `sw.js` con `lacava-v2`.
6. Prueba supervisada: alta de cliente, una conversión de contado y una de crédito.
7. Vuelta atrás: procedimiento de la sección "Reversión".
