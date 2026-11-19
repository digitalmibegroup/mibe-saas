# Plan: ensayo de «Ocultar productos en Inventario» en el staging `ca10112ba2`

**Estado:** preparación local. **No se conectó ni se escribió en ninguna base.** Nada se ejecuta sin la autorización de Michel. No toca producción.
Solución a ensayar: la actual, con sus limitaciones documentadas (`INVENTARIO_OCULTAR_PRODUCTOS.md`). **Sin triggers ni funciones nuevas de base.**

## 1. Revisión del SQL
| Archivo | Qué hace | Revisión |
|---|---|---|
| `INVENTARIO_OCULTAR_PRODUCTOS.sql` | `ALTER TABLE public.inventario ADD COLUMN IF NOT EXISTS oculto boolean NOT NULL DEFAULT false` + `COMMENT` | Una sola columna; sin índices, políticas, permisos, triggers ni funciones. Con valor por defecto constante no reescribe la tabla ni dispara triggers de fila (los de v5 y H1 no se ejecutan). Idempotente. Toma un bloqueo breve de tabla: el lanzador lo envuelve en una transacción con `lock_timeout = 5 s`. |
| `INVENTARIO_OCULTAR_PRODUCTOS_REVERTIR.sql` | `DROP COLUMN IF EXISTS oculto` | Solo pierde las marcas de ocultos; ningún otro dato. |
| `INVENTARIO_OCULTAR_PRODUCTOS_VERIFICAR.sql` | Solo lectura: `INSTALADO`/`NO_INSTALADO`, total y ocultos | — |
| `INVENTARIO_OCULTAR_PRODUCTOS_PRECHEQUEO_STAGING.sql` (nuevo) | Foto de solo lectura de `inventario`: dueño y si el usuario puede alterarla, RLS, políticas, disparadores, ACL (tabla y columnas), privilegios de `anon`/`authenticated` sobre la columna, conteos y huella md5 de los datos **sin** la columna | Se ejecuta antes y después; solo pueden cambiar las líneas `COLUMNA|` y `PRIVILEGIO|*_oculto`. |
Probado en un PostgreSQL local (instalar → foto igual salvo la columna; revertir → foto idéntica a la inicial). Durante esa prueba se corrigió un error de tipo en la foto antes de llegar a staging.

**Riesgo propio de staging (a vigilar, no a corregir):** si `authenticated` tuviera permisos *por columna* en `inventario`, la columna nueva no sería escribible; la foto lo informa (`PRIVILEGIO|authenticated_oculto`) y el lanzador marca el ensayo como fallido si no es `SELECT=true,UPDATE=true`. No se amplía ningún privilegio.

## 2. Comandos (protegidos contra producción; **no ejecutar hasta que Michel autorice**)
Un solo lanzador, tres acciones. Pide servidor, usuario y base del **Session pooler de staging** (la contraseña la pide PostgreSQL), rechaza producción por huella SHA-256, exige huella `ca10112ba2` y el esquema `staging_marca`, fija el SHA-256 de los 4 SQL (si cambia uno, no ejecuta nada) y exige una frase distinta por acción. Deja evidencia nueva (nunca sobrescribe) en `%USERPROFILE%\LaCava-evidencia-local\inventario-ocultar-staging-ca10112ba2\`.
```
# 1) Verificar (SOLO LECTURA) — primer comando, sin riesgo
powershell -ExecutionPolicy Bypass -File ".\ENSAYO-OCULTAR-INVENTARIO-EN-STAGING.ps1" -Accion Verificar      # frase: VERIFICAR OCULTAR EN STAGING
# 2) Instalar (ESCRIBE: solo la columna) — exige que la columna NO exista y que el usuario sea dueño de la tabla
powershell -ExecutionPolicy Bypass -File ".\ENSAYO-OCULTAR-INVENTARIO-EN-STAGING.ps1" -Accion Instalar       # frase: INSTALAR OCULTAR EN STAGING
# 3) Revertir (ESCRIBE: elimina la columna) — al terminar el ensayo, si Michel lo decide
powershell -ExecutionPolicy Bypass -File ".\ENSAYO-OCULTAR-INVENTARIO-EN-STAGING.ps1" -Accion Revertir       # frase: REVERTIR OCULTAR EN STAGING
```
Verificado en local sin conectar: un usuario con formato inválido y un proyecto con otra huella se detienen **antes** de conectar; un SQL modificado se niega.
Códigos: 0 correcto · 1 Docker · 2 datos/estado previo no válidos (no escribió) · 3 la escritura falló (se deshizo todo) · 4 sin confirmación o proyecto distinto · 5 la comprobación posterior no cumple.

## 3. Datos ficticios (id `ens-ocu-*`, nombre «… (ENSAYO OCULTAR)», categoría «Ensayo ocultar»)
Se crean con `tests/inventario-ocultar/ensayo-staging/ensayo-staging-inventario-semilla.cjs` como el **usuario ficticio autenticado** (el mismo mecanismo de la fase C del hotfix: staging tiene H1), sin tocar productos reales ni los `ens-*` de ensayos anteriores.
| Producto | Estado inicial | Caso que prueba |
|---|---|---|
| `ens-ocu-cero` | stock 0, sueltas 0 | ocultar, volver a mostrar, persistencia |
| `ens-ocu-stock` | stock 5 | rechazo con existencias (principal) |
| `ens-ocu-sueltas` | six-pack, stock 0, **3 sueltas** | rechazo con unidades sueltas |
| `ens-ocu-bodega` | principal 0, **4 en bodega** | rechazo con existencias en bodega |
| `ens-ocu-entrada` | stock 0, **ya oculto** | entrada de stock → reaparece y se limpia la marca |
La bodega: se usa la que tenga staging; **solo si no hay ninguna** se crea «Bodega (ENSAYO)». `--reiniciar` devuelve los 5 productos a su estado inicial; `--retirar` los borra (solo con el servidor en modo `--permitir-retirada`).

## 4. Copia local del dashboard conectada solo a staging
`servidor-ensayo-inventario.cjs` sirve **la copia local de esta rama** en `http://127.0.0.1:5192` (solo `SB` cambia; el HTML no contiene la URL, las claves ni el JWT) y reenvía a staging con la clave anon y el JWT del usuario ficticio (se piden por terminal y viven solo en memoria; frase `ABRIR SERVIDOR OCULTAR INVENTARIO EN STAGING`). Lista blanca de escrituras: `inventario`, `inventario_bodega` y `producto_presentaciones` **solo** de `ens-ocu-*`, la bodega de ensayo y `lacava_mi_sesion`; **todo lo demás recibe 403 y queda en el registro** (también ventas, compras, cotizaciones, caja, productos reales). Sin DELETE salvo `--permitir-retirada`.
```
node tests/inventario-ocultar/ensayo-staging/servidor-ensayo-inventario.cjs [--permitir-retirada]
node tests/inventario-ocultar/ensayo-staging/ensayo-staging-inventario-semilla.cjs --base http://127.0.0.1:5192
```

## 5. Pasos del ensayo en el navegador y resultado esperado
Inventario → pestaña Principal. Tras cada paso, `ensayo-staging-inventario-semilla.cjs --base … ` muestra el estado en la base.
| # | Acción | Esperado |
|---|---|---|
| 1 | Abrir Inventario | `ens-ocu-entrada` no aparece; el filtro dice «Ocultos (1)»; «Ocultar» solo en `cero` y `bodega` |
| 2 | Ocultar `ens-ocu-cero` | desaparece; «Ocultos (2)»; en la base `oculto=true` (una sola escritura, solo la marca) |
| 3 | Filtro «Ocultos» → «Volver a mostrar» `cero` | vuelve a la lista; `oculto=false` |
| 4 | Ocultar `cero` otra vez, **recargar** (F5) y abrir en **otro navegador/perfil** | sigue oculto en ambos (persistencia entre recargas y dispositivos) |
| 5 | Ocultar `ens-ocu-bodega` | rechazo «existencias en la bodega»; nada cambia |
| 6 | `ens-ocu-sueltas` y `ens-ocu-stock` | sin botón «Ocultar» |
| 7 | Con `cero` visible: darle una Entrada de 2 unidades desde **otro perfil del navegador** y, en el primero (sin recargar), pulsar «Ocultar» sin recargar | rechazo «existencias en el inventario principal» y la fila se corrige |
| 8 | «Entrada de mercancía» sobre `ens-ocu-entrada`: 3 unidades | reaparece en la lista; `oculto=false` en la base; «Ocultos» baja en 1 |
| 9 | Llevar ese producto otra vez a 0 (Ajuste) **sin abrir** otra pantalla y abrir Inventario | sigue visible (la marca ya se había limpiado al recibir) |
| 10 | Revisar el registro del servidor (`/__log`) | ninguna escritura fuera de `ens-ocu-*`; ningún 403 inesperado |

## 6. Qué modifica cada paso en staging (todo identificable)
| Paso | Modifica | Autorización |
|---|---|---|
| Verificar | Nada | Michel lo ejecuta |
| Instalar | Solo la columna `inventario.oculto` | Expresa |
| Datos (sección 3) | Inserta 5 productos `ens-ocu-*`, 1 fila de bodega, y la bodega de ensayo solo si no existía | Expresa |
| Pasos 2–9 | Actualiza solo esos productos; la entrada con costo puede crear su fila en `producto_presentaciones` | Incluida en la anterior |
| Cierre | `--retirar` (borra `ens-ocu-*`) y, si se quiere, `Revertir` (elimina la columna) | Expresa y aparte |
Efectos que **no se pueden devolver** (como en los ensayos anteriores): los contadores de v5 (`lacava_version_cambios`) avanzan con cada actualización de `inventario`; quedan huecos, no datos. **No se tocan** los datos ni los ensayos anteriores.

## 7. Limitaciones de representatividad
1. **Acceso:** staging tiene H1, así que el ensayo corre como `authenticated` con RLS por licencia. Producción usa `anon` sin H1 (la política `anon_all_inventario` ya cubre la columna: probado en local). No se abre ningún acceso anónimo para este ensayo.
2. **Datos:** copia anonimizada; sin volumen ni concurrencia real.
3. **No se puede simular en staging** la limpieza fallida (red) ni la carrera de bodega: ya están cubiertas con la base simulada local.
4. Es la copia local del dashboard (no la publicada) y no registra el service worker.

## 8. Decisiones pendientes
1. Autorizar el **primer comando (Verificar, solo lectura)** para confirmar dueño, permisos de columna y estado actual.
2. Autorizar **Instalar** y los **datos ficticios** (secciones 2 y 3) en una ventana definida.
3. Al cerrar: ¿`--retirar` y/o `Revertir`, o dejar la columna instalada?
