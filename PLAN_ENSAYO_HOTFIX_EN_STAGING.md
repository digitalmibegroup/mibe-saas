# Plan: ensayo del hotfix de cotizaciones solo en el staging `ca10112ba2` (v5 + H1)

**Estado:** preparación local. No se conectó ni se modificó ninguna base. No se crean proyectos ni se contrata nada. v5 y H1 se conservan, con sus datos y evidencias; el plan solo **añade** objetos y datos ficticios y **retira** únicamente lo que añade. El borrador de Michel y la copia de integración no se tocaron (la copia de integración solo se **leyó**).

## 1. Compatibilidad local del SQL con v5 + H1

Probado en PostgreSQL temporal con la base de integración (esquema + seguridad de producción + paquete real v5 + H1 + perfiles ficticios). No se ejecutó `esquema-produccion-minimo.sql` sobre staging ni se hará.

| Punto | Resultado |
|---|---|
| Instalar `HOTFIX_COT_CONVERSION_ATOMICA.sql` sobre v5 + H1 | Se instala; el verificador no da `ERROR`. Sin colisiones de nombres, columnas, índices ni políticas (v5/H1 no usan `cotconv_*`) |
| Columnas | Las del hotfix existen. H1 añade `cartera_abonos.idem_key` (el abono espejo la deja NULL: sin problema) y v5 añade `costo_ficha_venta`, `uds_ficha_venta` y `costo_registrado` al detalle |
| Disparadores de v5 | `detalle_ventas_costo` rellena los costos del detalle de la conversión (comprobado). `inventario_contar_cambios` consume la secuencia `lacava_version_cambios` |
| Disparadores de H1 | `validar_referencias`, `forzar_licencia` y `fijar_registrado` actúan cuando hay sesión (`auth.uid()`). El abono espejo queda con `registrado_por` = nombre del perfil (no `'pos'`): coherente |
| Abonos | Un abono posterior con `lacava_registrar_abono_cartera` (H1) se acepta sobre la cartera creada por la conversión |
| RLS y permisos | H1 activa RLS sin FORCE y revoca todo a anon. Las 15 políticas del hotfix son solo para `cotconv_ejecutor` y funcionan. Los permisos de la tabla de registro siguen cerrados a anon y authenticated |
| **Hallazgo 1: acceso anónimo bajo H1** | Con el EXECUTE para anon que concede el instalador, **anon puede convertir sin sesión** (probado). Salta el "sin acceso anónimo" de H1. Un usuario de otra licencia que envía `p_id_licencia` ajeno lo frena `validar_referencias` (LH004); sin perfil, LH001 |
| **Hallazgo 2: orden con H1** | `H1_02` elimina **todas** las políticas de `public` y `H1_REVERTIR` restaura desde su foto: **borra las 15 políticas** del hotfix. Tras revertir H1 con el hotfix instalado, el rol y la función siguen pero fallan con un `CV010` engañoso |

**Consecuencias:**
- **Producción hoy** (sin H1, acceso por anon): nada cambia; el SQL aprobado es el correcto.
- **En este staging (H1)**, el ensayo se hace con el SQL aprobado **sin modificarlo**, y justo después de instalar se ejecuta `REVOKE EXECUTE ... FROM anon` sobre las dos funciones (fase 1).
- **Cambio necesario antes de combinar el hotfix con H1 en producción** (no se implementa ahora): si existe `app.licencia_actual()`, exigir `p_id_licencia = app.licencia_actual()` y no conceder EXECUTE a anon (más `USAGE` en `app` y `EXECUTE` en esa función para el rol dueño). Además, `H1_REVERTIR` debería avisar de que el hotfix está instalado.
- **Regla de orden:** el hotfix se instala **después** de H1 y se revierte **antes** que H1.

## 2. Cómo se ensaya cada parte

**Instalación con el rol real de Supabase.** El instalador y el verificador se aplican con una sesión del Session pooler como `postgres` del proyecto, usando el patrón de los lanzadores de staging existentes (huella de producción rechazada, `staging_marca`, frase de confirmación). Es la prueba que falta: crear `cotconv_ejecutor` y transferir la propiedad. Si Supabase lo rechaza, me detengo y entrego el error; no se sustituye el dueño por `postgres`.

**RPC mediante PostgREST (fase 1, H1 intacto).** Con el JWT de un usuario ficticio con perfil activo:
- el guion `ensayo-postgrest.cjs` se adapta con un modo "autenticado" (token por contraseña, sin eco);
- hay que cambiar su comprobación de licencia, de huella de producción a la huella de `ca10112ba2`, y su comprobación previa "anon NO puede…" (bajo H1 es aún más estricta);
- se prueban los pagos, el reintento, la clave en conflicto, los dos envíos simultáneos, el acceso directo al registro y la venta eliminada.

**Los tres ajustes desde el navegador.** Una copia del dashboard del hotfix (derivado del publicado):
- se guarda fuera del repositorio y se sirve en localhost;
- cambia solo `var SB` y añade un pequeño envoltorio de `fetch` que reemplaza el encabezado `Authorization` por el JWT del usuario ficticio;
- así prueba cliente con dirección, guardar y reabrir cotización, conversión de efectivo, transferencia y crédito, el corte de red con **Reintentar** y las dos pestañas, bajo H1 y como `authenticated`.

La copia nunca se publica, apunta solo a staging y rechaza cualquier otro origen.

## 3. Qué se puede probar con H1 intacto y qué no

| Con H1 intacto (fase 1) | No se puede ver (necesita la fase 2) |
|---|---|
| Instalación con el rol real, RPC por PostgREST, los tres ajustes y toda la lógica de conversión como `authenticated` con perfil | El camino **anon** de producción: la clave anon pública sin sesión sobre tablas abiertas, y la copia del dashboard **sin** el envoltorio de JWT |

**Fase 2 (opcional, autorización aparte): reproducir el acceso anónimo de producción.** Solo si Michel la autoriza, **sin desactivar H1 ni tocar sus políticas** y solo para las 7 tablas de los tres flujos más `licencias`. Esto enumera exactamente qué se abriría:

```
-- ABRIR (fase 2)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.cotizaciones, public.clientes_frecuentes, public.inventario,
      public.ventas, public.detalle_ventas, public.cartera, public.cartera_abonos TO anon;
GRANT SELECT ON public.licencias TO anon;
CREATE POLICY ens_anon_cotizaciones ON public.cotizaciones FOR ALL TO anon USING (true) WITH CHECK (true);   -- y la misma para
  -- clientes_frecuentes, inventario, ventas, detalle_ventas, cartera, cartera_abonos (7 politicas FOR ALL)
CREATE POLICY ens_anon_licencias ON public.licencias FOR SELECT TO anon USING (true);
GRANT EXECUTE ON FUNCTION public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb),
                          public.cotizacion_conversion_info(text,uuid) TO anon;
```

- **No** se tocan secuencias, otras tablas (caja, gastos, puntos, ventas en espera), funciones de H1 ni las políticas de H1. Fuera de los tres flujos, el dashboard mostrará errores 401: es esperado.
- **Valores anteriores:** el prechequeo ya captura la ACL exacta (`ACL|…`), las políticas (`POLITICA|…`) y las ACL de funciones (`ACL_FUNCION|…`) en una evidencia que nunca se sobrescribe. Hoy se espera `anon` sin nada en esas tablas.
- **Restaurar:** `REVOKE ALL ON <las 8 tablas> FROM anon`; `DROP POLICY ens_anon_<tabla>` (8); `REVOKE EXECUTE … FROM anon` (2 funciones). Verificación: repetir el prechequeo y comparar las líneas `ACL|`, `ACL_FUNCION|` y `POLITICA|` con la evidencia previa. Deben coincidir salvo los objetos propios del hotfix.
- **Riesgo durante la fase 2:** cualquiera con la clave anon de staging (datos anonimizados) tendría acceso a esas 8 tablas. Se hace en una ventana corta y se restaura al terminar.

## 4. Datos ficticios identificables y su retirada

**Datos (todos con "(ENSAYO)"):**

| Dato | Identificación |
|---|---|
| 2 productos | ids `ens-cerveza6` (empaque x6, 100 empaques + 2 sueltas) y `ens-ron`; así **no se toca el inventario real** |
| 1 cliente | id `5e5e5e5e-0000-4000-8000-0000000000e1`, WhatsApp `3000000001`, dirección ficticia |
| Cotizaciones | `cliente_nombre` con "(ENSAYO)" y líneas con `prod_id` que empieza por `ens-` |
| Ventas, detalles, cartera y abonos | Solo los creados por esas cotizaciones |

Se crean como `authenticated` con perfil, en la licencia del perfil de staging.

**Retirada, solo de lo anterior, como `authenticated` (flujo normal; probado localmente):**
1. por cada cotización ficticia: desvincular, borrar detalle y borrar la venta (cartera y abonos se van en cascada);
2. borrar las cotizaciones, el cliente y los dos productos;
3. repetir el prechequeo: los conteos `DATOS|…` deben igualar la línea base, salvo lo que queda a continuación.

**Lo que NO se puede ni se debe retirar** (identificado, sin contenido de clientes):
- **Registro `cotizacion_conversiones`:** una fila por conversión. Es de solo añadir, a propósito. Solo se elimina con `REVERTIR` + `DROP TABLE`, y esa tabla contiene únicamente filas del ensayo.
- **Eventos de auditoría de H1:** como mucho 1, por el abono posterior; `authenticated` no puede borrarlos y no se borra auditoría. Si Michel prefiere cero, se omite ese abono.
- **Contadores:** `ventas_numero_venta_seq` y `lacava_version_cambios` avanzan y no se devuelven (solo dejan huecos).
- Operaciones anteriores de v5, H1 y sus datos: **no se tocan**.

**Cierre:** `REVERTIR` del hotfix (conserva el registro y su protección). El `DROP TABLE` del registro, si se quiere dejar staging sin rastro del hotfix, es una decisión aparte. La comparación final con la línea base mostrará únicamente las diferencias anteriores.

## 5. Modificaciones exactas que requeriría staging, por fase

| Fase | Qué modifica en staging | Autorización |
|---|---|---|
| A. Prechequeo (**primer comando**) | Nada (sesión de solo lectura) | Michel lo ejecuta |
| B. Instalar | Crea rol `cotconv_ejecutor`, tabla `cotizacion_conversiones` con su índice y 2 disparadores, función `cotconv_registro_inmutable`, 15 políticas, 2 funciones y sus permisos; luego `REVOKE EXECUTE … FROM anon` (2 funciones) | Expresa |
| C. Datos y RPC (fase 1) | Inserta los datos ficticios; crea ventas, detalles, cartera, abonos y registro; modifica el stock de `ens-*`; consume secuencias; como mucho 1 evento de auditoría | Expresa |
| D. Navegador | Lo mismo que C, desde la copia local del dashboard | Incluida en C |
| E. Fase 2 anon (opcional) | Las concesiones y políticas de la sección 3, y su restauración | Expresa y aparte |
| F. Retirada y cierre | Borra los datos ficticios; `REVERTIR` del hotfix; opcional `DROP TABLE` del registro | Expresa |

**Prerrequisito de C/D:** un usuario ficticio de Auth (correo `.invalid`) con perfil activo y `id_cliente` igual al de la licencia del staging. El prechequeo informa `H1|perfiles_activos` y `H1|usuarios_auth`. Si no existe, Michel lo crea en el panel y se ejecuta la fase `Perfil` del lanzador existente (una fila en `app.perfiles_usuario`).

**Scripts que prepararé después de aprobar el plan (sin efecto en staging):**
- lanzador de las fases B, E y F;
- modo "autenticado" del guion;
- generador de la copia local del dashboard.

## 6. Limitaciones de representatividad frente a producción

1. **Acceso:** staging tiene H1 (producción no). La fase 1 prueba como `authenticated` con RLS por licencia, no como anon. La fase 2 reproduce anon solo en 8 tablas, y los disparadores de H1 no actúan con anon (como en producción).
2. **Datos:** copia anonimizada (mismos ids, filas, montos y stock; sin nombres ni teléfonos reales). No hay volumen de producción ni de otras licencias.
3. **Dashboard:** el publicado no usa Supabase Auth; la copia necesita el envoltorio de JWT en la fase 1. Las pantallas ajenas a los tres flujos pueden mostrar errores bajo H1.
4. **Instalación:** el rol y el pooler son los reales de Supabase (esto sí es representativo), pero el producto de producción no tiene el esquema `app` ni los disparadores de v5 y H1.
5. **No se prueba:** carga, concurrencia real de varios locales, Realtime, caja, reportes, ni el comportamiento combinado hotfix + H1 en producción (requiere el cambio descrito en la sección 1).
6. **Staging con v5:** sus operaciones de Compras no interfieren (tablas distintas), pero hacen que staging no pueda volver a su estado original: el ensayo debe dejarlo igual que antes salvo lo documentado.

## Primer comando (solo lectura)

```
powershell -ExecutionPolicy Bypass -File "C:\Users\USUARIO\Proyectos - Claude code\La Cava licorera\mibe-saas-hotfix-cotizaciones\COMPROBAR-HOTFIX-EN-STAGING.ps1"
```

Pide servidor, usuario y base del Session pooler de **staging** (la contraseña la pide PostgreSQL), rechaza producción, exige que la huella sea `ca10112ba2` y el esquema `staging_marca`, y la frase `COMPROBAR EN STAGING`. Deja una evidencia nueva en `%USERPROFILE%\LaCava-evidencia-local\hotfix-staging-ca10112ba2\`. Código de salida 0 = nada impide el ensayo; 5 = hay un motivo y se detiene.
