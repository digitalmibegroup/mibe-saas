# Procedimiento de producción — Hotfix "Convertir cotización en venta" (atómico)

Estado: **preparado, sin ejecutar**. Nada de esto toca producción hasta que Michel lo autorice paso a paso. Lo ejecuta Michel
(o Claude con su autorización expresa por cada paso que escribe). Producción hoy: **sin H1**, acceso por la clave **anon**.

## 0. Qué se publica (hashes finales)

SQL (en producción, en este orden: VERIFICAR → instalar → VERIFICAR):

| Archivo | SHA-256 |
|---|---|
| `HOTFIX_COT_CONVERSION_ATOMICA.sql` (instala; concede EXECUTE a `anon` y `authenticated`) | `e07dd6866f56c63c0bb2801cb2071c084159770ac48aef9c8a4fed8cf01f9e27` |
| `HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql` (solo lectura) | `275c56e9cc6929528aeb83788a32c63818aeb96dbea9e5bc039c39e2fedb890f` |
| `HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql` (vuelta atrás) | `8ca53b6504bb97274808d083f2b5d7847dc1325f7a3d7689b3f934c1c4250a81` |

Deploy (lo que Netlify publica desde `deploy/`; los tres HTML son idénticos entre sí y al `dashboard_lacava.html` de la raíz):

| Archivo | SHA-256 | blob git |
|---|---|---|
| `deploy/index.html`, `deploy/dashboard_lacava.html`, `dashboard_lacava.html` | `dbec02f41bfbdb3e40d30790f80c8c649207b09fa60d6f0e4b8b7d4fa9db9e42` | `c4e25923e2c7…` |
| `deploy/sw.js` (cache `lacava-v2`; antes `lacava-v1`) | `48abb022cfa254cc8518e887f8fa0f89c51a56ee41b3df14f1e3421fc211edf9` | `7c665e261157…` |

Si cambia un solo byte de cualquiera de estos archivos, los hashes de arriba dejan de valer y hay que repetir el ensayo.

## 1. Archivos exactos del commit

Se comprobó con un **clon limpio** (historial desde `eacde3b` + solo los archivos de esta lista + `tests/`): las pruebas corren ahí sin tocar nada más
(ver `tests/hotfix-cotizaciones/LEEME.md`: requisitos de entorno y qué se omite si faltan). Sin esos archivos, 13 pruebas fallaban por dependencias que no
estaban en el commit.

**Producción (4 archivos de la aplicación + 3 SQL):**
```
dashboard_lacava.html
deploy/dashboard_lacava.html
deploy/index.html
deploy/sw.js
HOTFIX_COT_CONVERSION_ATOMICA.sql
HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql
HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql
```
**Dependencias de las pruebas y herramientas del procedimiento (no se publican en Netlify, pero deben ir en el commit):**
```
tests/hotfix-cotizaciones/                       (carpeta completa, incluida LEEME.md)
HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql   (variante de staging; la leen las pruebas)
ANON_ENSAYO_STAGING_CAPTURA.sql  ANON_ENSAYO_STAGING_ABRIR.sql  ANON_ENSAYO_STAGING_RESTAURAR.sql   (las leen las pruebas)
PRECHEQUEO_HOTFIX_EN_STAGING.sql  PERFIL_ENSAYO_STAGING.sql
COMPROBAR-HOTFIX-EN-STAGING.ps1  INSTALAR-HOTFIX-EN-STAGING.ps1  LEER-PERFIL-ENSAYO-STAGING.ps1
FASE-ANON-ENSAYO-STAGING.ps1  RECUPERAR-HOTFIX-EN-STAGING.ps1  REINSTALAR-HOTFIX-EN-STAGING.ps1  VERIFICAR-RESPALDO-RESTAURANDO-LOCAL.ps1
INFORME_HOTFIX_COTIZACIONES.md  PLAN_ENSAYO_HOTFIX_EN_STAGING.md  ENSAYO_COT_CONVERSION_POSTGREST.md (SUPERADO)  PROCEDIMIENTO_PRODUCCION_HOTFIX_COTIZACIONES.md
```
Los `.ps1` traen como valor por defecto una ruta de la máquina de Michel (`STAGING-COMUN.ps1` de la copia de integración, solo lectura); se pasa con `-Comun` en otro equipo.
**No van** (ni se tocan): la copia de integración v5–v8 (`mibe-saas-integracion-compras`), el borrador (`mibe-saas`), ninguna evidencia (`LaCava-evidencia-local`), dumps, `.env` ni claves.
Antes de commitear: `git status` debe mostrar solo estas rutas.

## 2. Orden y pasos

El orden importa: **la base primero, el frontend después** (el frontend nuevo sin la función instalada solo informa "conversión
segura no instalada" y no escribe; la función sin frontend nuevo no se usa).

1. **Condiciones.** Franja sin ventas en curso y **caja cerrada**. Michel autoriza este procedimiento por escrito.
2. **Respaldo previo (solo lectura).** Ejecutar `mibe-saas-integracion-compras\pruebas-locales\base-temporal\RESPALDAR-PRODUCCION-SOLO-LECTURA.ps1`
   (pg_dump de PostgreSQL 17 en Docker contra el Session pooler, sesión forzada a solo lectura; pide servidor, usuario y contraseña en
   pantalla). Guarda el respaldo fuera del repositorio con manifiesto y SHA-256. **No continuar si no termina con código 0.** Anotar
   nombre, SHA-256 y filas de `ventas`, `cotizaciones`, `cartera`, `cartera_abonos` e `inventario`.
   **Comprobar el respaldo restaurándolo en local (no basta el hash):**
   ```bash
   powershell -ExecutionPolicy Bypass -File .\VERIFICAR-RESPALDO-RESTAURANDO-LOCAL.ps1 -Respaldo "C:\Users\<usuario>\LaCava-respaldos\<carpeta>\<respaldo>.dump"
   ```
   Levanta un PostgreSQL 17 desechable **sin red**, restaura con `pg_restore` (0 errores), compara las filas de **cada** tabla con el manifiesto, comprueba que existen
   los objetos que usa el hotfix (índice único de ventas por cotización, `cartera_venta_id_unique`, secuencia de ventas, RPC de abonos y las columnas necesarias) y que la copia es
   consultable; borra el contenedor y deja la evidencia en `LaCava-evidencia-local\verificacion-respaldo`. **Solo con código 0 el respaldo sirve como punto de vuelta atrás; si no, no se sigue.**
   (Probado con el dump anonimizado: 25 tablas, 5 500 filas, 0 errores.)
3. **Lectura previa (solo lectura, SQL Editor de producción).**
   - Ejecutar `HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR_UNA_TABLA.sql` (las mismas consultas del `..._VERIFICAR.sql` auditado reunidas en **una** instrucción, porque el SQL Editor
     solo muestra el resultado de la última; generado por `tests/hotfix-cotizaciones/ensayo/generar-verificar-una-tabla.cjs` y comprobado línea a línea contra el original,
     antes y después de instalar): debe terminar en `RESULTADO|NO_INSTALADO`. **Cada comprobación se ejecuta por separado y se anota su salida.**
   - Ejecutar `PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql` (un solo SELECT, una sola tabla de resultados). Distingue venta_id inexistente,
     `SIN_VENTA_ID`, enlace inverso ausente, enlaces contradictorios y enlaces compartidos. Esperado: `RESULTADO|CONFORME_CON_EXCEPCION_DOCUMENTADA_10`
     (10 filas `ENLACE_INVERSO_AUSENTE|<id>|en_la_lista_documentada`, ninguna `OTRA_ANOMALIA`). **Cualquier otro resultado: detenerse.**
     *(La comprobación original, "0 cotizaciones convertidas sin `ventas.cotizacion_id`", se sustituye por esta: producción tiene 10 conversiones
     históricas de agosto de 2026 cuya venta existe pero no guarda el enlace inverso.)*
   - `SELECT last_value FROM ventas_numero_venta_seq;` (anotar; el 2026-11-18 era **1171**).

   **Excepción documentada (solo estas 10 cotizaciones, verificadas el 2026-11-18 sobre el respaldo 20261118-143826 y con el recuento en producción):**
   `71f5c2bf-386f-49fb-903d-077a6c4c9a5d`, `3c94d8e6-efea-4ecc-a19f-62f8f1bae070`, `d2558e2e-a56d-4ae4-9205-1c4d80181619`,
   `7bb665e6-178e-4ee8-a10b-5d8d4dffdb03`, `6a6df08d-aad3-4427-8fff-b5ef8e9460f3`, `a07cbac7-b248-496a-b05a-c1e5ff2b3f0e`,
   `5b8fa3c4-b401-4e90-9df2-79f1af77edf7`, `200f8968-fbe6-40ea-b2f6-2170efae7d5f`, `61a4da72-5368-4923-b5e7-080169a44c8c`,
   `5d40d4b0-d697-41c1-9ee9-dbecbd721447`. Todas: estado `convertida`, `venta_id` apunta a una venta existente, de la misma licencia, completada;
   la venta tiene `cotizacion_id` vacío. **No se reparan** (decisión de Michel). Con el hotfix: se siguen mostrando como "Convertida" (no como incompletas), no se
   pueden editar, eliminar ni reconvertir (`CV011`), y el intento no modifica ventas, inventario, cartera, abonos ni el registro. Ensayo sobre la copia local
   del respaldo: `tests/hotfix-cotizaciones/ensayo/ensayo-copia-respaldo.ps1` (instala, 10 cotizaciones × 4 intentos como anon → `CV011` en 40/40, huellas de
   13 tablas y secuencia idénticas antes y después, y 7 controles que provocan cada anomalía y exigen `NO_CONFORME`).
4. **Instalar la base.** Pegar **completo** `HOTFIX_COT_CONVERSION_ATOMICA.sql` en el SQL Editor de **producción** y ejecutarlo una vez. Es una sola
   transacción: si algo falla, no queda nada. Si Supabase rechaza un paso (crear el rol, cambiar dueño), **detenerse** y no improvisar
   (en staging el rol real de Supabase sí lo permitió).
5. **Verificar.** Ejecutar `..._VERIFICAR_UNA_TABLA.sql` (equivalente al `..._VERIFICAR.sql`): esperado `RESULTADO|INSTALADO`, **sin ninguna línea `ERROR|`**, 2 funciones con
   `definer=true|dueno=cotconv_ejecutor`, `anon_exec=true|auth_exec=true|public_exec=false`, y `PRIVILEGIO|anon|cotizacion_conversiones|` y
   `PRIVILEGIO|authenticated|cotizacion_conversiones|` **vacíos** (el registro cerrado).
6. **Commit y push** (solo con la base verificada y autorización expresa):
   ```bash
   git switch -c hotfix/cotizaciones-conversion-atomica
   git add dashboard_lacava.html deploy/dashboard_lacava.html deploy/index.html deploy/sw.js \
           HOTFIX_COT_CONVERSION_ATOMICA.sql HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql \
           HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR_UNA_TABLA.sql HOTFIX_COT_CONVERSION_ATOMICA_MEMBRESIAS.sql PRECHEQUEO_COTIZACIONES_CONVERTIDAS_PRODUCCION.sql \
           INFORME_HOTFIX_COTIZACIONES.md PLAN_ENSAYO_HOTFIX_EN_STAGING.md ENSAYO_COT_CONVERSION_POSTGREST.md PROCEDIMIENTO_PRODUCCION_HOTFIX_COTIZACIONES.md \
           tests/hotfix-cotizaciones   # + el material de ensayo en staging (variante, PRECHEQUEO/PERFIL/ANON_*.sql y los 7 lanzadores .ps1) ya revisado
   git status          # debe listar solo esas rutas
   git commit -m "fix(cotizaciones): conversion en venta atomica con registro de idempotencia"
   git push -u origin hotfix/cotizaciones-conversion-atomica
   # integrar en main segun el flujo habitual del repositorio y hacer push de main: Netlify publica deploy/
   ```
7. **Comprobar el despliegue** (cuando Netlify termine):
   - El HTML servido es el nuevo: `curl -s https://<sitio>/dashboard_lacava.html | sha256sum` → `dbec02f4…db9e42` (los bytes servidos son los del commit, con saltos LF).
   - `curl -s https://<sitio>/sw.js | grep "CACHE ="` → `lacava-v2`.
   - **Aviso a los usuarios:** el service worker sirve primero la página guardada. Tras publicar, la **primera** carga puede seguir mostrando la
     versión anterior; la **segunda** (o cerrar y abrir la app) muestra la nueva y borra la cache `lacava-v1`. Probado: 2 cargas.
8. **Primera operación real** (Michel la comprueba): **no se crean ventas ni clientes ficticios en producción**. La primera conversión real se revisa con Michel
   (venta, inventario, cartera y abono si los hay).
9. **Después:** ejecutar de nuevo el VERIFICAR y guardar su salida junto con el respaldo.

## 3. Vuelta atrás (en este orden)

1. Publicar el frontend anterior: `git revert <commit>` del merge y push (o redeploy del deploy anterior en Netlify). Si no, "Convertir en venta" informa que la conversión segura no está instalada y no registra nada.
2. VERIFICAR (anotar `REGISTRO|operaciones=N`), luego `HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql` (lee el aviso), luego VERIFICAR otra vez: esperado `NO_INSTALADO`.
3. Con registro vacío, el REVERTIR elimina también la tabla; con operaciones, la **conserva** (solo añadir, sin privilegios para anon). Ventas, carteras, abonos e inventario creados se conservan siempre.
4. Si hace falta volver a un estado anterior de datos: restaurar desde el respaldo del paso 2 es una decisión aparte y destructiva; no forma parte de este procedimiento.

## 3b. Defecto equivalente corregido en el instalador de producción

El ensayo anon en staging mostró que `GRANT/REVOKE EXECUTE` hecho por un administrador que **no es dueño** de la función no surte efecto si no
tiene membresía en el rol dueño (solo avisa: "no privileges were granted"). El instalador de producción ya otorgaba EXECUTE con la
membresía temporal activa y lo verificaba antes del COMMIT, pero **toleraba** que fallara el retiro de esa membresía (solo avisaba) y no lo
comprobaba. Ahora el retiro es estricto y la verificación final exige que no quede membresía con SET/INHERIT. Probado en local con un
administrador sin superusuario (`tests/hotfix-cotizaciones/pg/instalador-produccion.test.cjs`, 5 pruebas): EXECUTE efectivo para `anon` y
`authenticated`; tres mutaciones del instalador (GRANT tras retirar la membresía, sin GRANT, sin retirar la membresía) fallan antes del COMMIT y no dejan nada.
El `DROP FUNCTION` del REVERTIR funciona porque el administrador es dueño del esquema `public` (en Supabase lo es `pg_database_owner`).

El ensayo local de recuperación (`tests/hotfix-cotizaciones/ensayo/recuperacion.test.cjs`) encontró además un defecto en el REVERTIR: `REVOKE ALL ON ALL TABLES IN SCHEMA public`
falla ("permission denied") si alguna tabla del esquema no pertenece al administrador, aunque el rol no tenga nada en ella. Ahora revoca solo en los objetos donde el rol
tiene permisos. La reversión y la reinstalación se comprueban con `RECUPERAR-HOTFIX-EN-STAGING.ps1` (ver el informe de recuperación).

## 4. Lo que producción NO tiene y el ensayo sí (limitaciones)

Staging tiene v5 + H1 (producción no): ahí los disparadores de H1 fijan `registrado_por` con el responsable del perfil; con acceso **anon**, como en producción,
queda `'pos'` (comprobado en el ensayo anon). El acceso anónimo de producción a las 8 tablas ya existe y este hotfix no lo cierra (solo cierra el registro).

## 4. Registro del despliegue en producción (2026-11-18)

- Condiciones: sin operaciones en curso, caja cerrada, sistema sin uso durante la actualización (confirmado por Michel).
- Respaldo previo: `respaldo-lacava-20261118-143826` (fuera del repositorio), SHA-256 `ebbfe2374b332f68260a2375aed036a146a92fdbe1c51208385a060eadb21633`;
  restauración local: `pg_restore` con 0 errores y 25 tablas / 6312 filas iguales al manifiesto. (Un primer respaldo, `…143340`, resultó ser de **staging** y se descartó;
  desde entonces el respaldo de producción se lanza con una guarda que valida la huella `cea2aa59…` antes de conectar.)
- Lectura previa: `RESULTADO|NO_INSTALADO` sin `ERROR|`; prechequeo `CONFORME_CON_EXCEPCION_DOCUMENTADA_10`; `ventas_numero_venta_seq` = 1171.
- Instalación: `HOTFIX_COT_CONVERSION_ATOMICA.sql` (producción) `e07dd6866f56c63c0bb2801cb2071c084159770ac48aef9c8a4fed8cf01f9e27`, ejecutado una vez en el SQL Editor: «Success. No rows returned».
- Verificación posterior: `RESULTADO|INSTALADO`, sin `ERROR|`, las dos funciones con `definer=true|dueno=cotconv_ejecutor|anon_exec=true|auth_exec=true|public_exec=false`,
  registro cerrado para anon y authenticated, `REGISTRO|operaciones=0`, y `RESULTADO_MEMBRESIAS|con_set_o_inherit=0` (solo la opción de administrador del creador del rol).
