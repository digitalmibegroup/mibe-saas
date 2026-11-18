> **SUPERADO (17-nov-2026):** Michel decidió no crear otro proyecto ni contratar nada. El ensayo se hará solo en el staging `ca10112ba2` (v5 + H1); ver [PLAN_ENSAYO_HOTFIX_EN_STAGING.md](PLAN_ENSAYO_HOTFIX_EN_STAGING.md). Este documento queda como referencia del enfoque anterior (proyecto separado en blanco con el esquema mínimo).

# Ensayo de la conversión atómica con PostgREST real, en un proyecto separado

**Estado:** preparado, **no ejecutado**. Todo lo de este documento escribe en una base remota, así que cada paso que modifica el proyecto de ensayo necesita la autorización expresa de Michel. Nada de esto toca producción.

## Objetivo

Confirmar, con PostgREST de Supabase real y un esquema lo más parecido posible al de producción, lo que las pruebas locales no pueden demostrar:
1. que el SQL se instala por el SQL Editor con el rol real `postgres` (propiedad de las funciones, rol nuevo, políticas, concesiones);
2. los códigos HTTP y el JSON de error reales de PostgREST (`CV…`, `42501`, `PGRST202`);
3. que el dashboard del hotfix completa los flujos contra ese proyecto;
4. que la reversión con y sin operaciones se comporta como se documenta.

## Requisitos

- Un proyecto Supabase **nuevo y separado**. **No** es producción (ref `egjlrcokerffuoqwbxlh`) ni el staging `ca10112ba2` (tiene operaciones de Compras v5).
- Esquema de producción **sin datos reales**: lo ideal es el esquema completo (restaurado desde el procedimiento de respaldo anonimizado, con autorización aparte). Alternativa rápida y menos fiel: aplicar `tests/hotfix-cotizaciones/pg/esquema-produccion-minimo.sql` en un proyecto en blanco. Reproduce las 7 tablas, sus restricciones, RLS y políticas de anon según la lectura del catálogo del 16-nov, pero no el resto de producción.
- Datos ficticios o anonimizados. Los pasos usan nombres con "(ENSAYO)".
- Las credenciales las escribe Michel de forma interactiva. No se pegan en el chat ni se guardan: la clave anon se pide sin eco y no se escribe en el resultado.

## Pasos

| # | Paso | Escribe en el proyecto | Quién |
|---|---|---|---|
| 1 | Ejecutar `HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql` en el SQL Editor. Esperado: `RESULTADO\|NO_INSTALADO`, sin líneas `ERROR\|`. | No (solo lectura) | Michel |
| 2 | Ejecutar `HOTFIX_COT_CONVERSION_ATOMICA.sql`. Esperado: termina en `COMMIT` sin errores. Si falla, no queda nada instalado (todo o nada). | **Sí** | Michel, con autorización |
| 3 | Ejecutar de nuevo el VERIFICAR. Esperado: `RESULTADO\|INSTALADO`, sin `ERROR\|`. Revisar a ojo las líneas `PRIVILEGIO\|anon\|cotizacion_conversiones\|` y `PRIVILEGIO\|authenticated\|cotizacion_conversiones\|` (vacías: sin ningún privilegio). | No | Michel |
| 4 | Si PostgREST aún no ve las funciones (HTTP 404 / `PGRST202`): `NOTIFY pgrst, 'reload schema';` y repetir. | Recarga de esquema | Michel |
| 5 | Desde la carpeta `tests/hotfix-cotizaciones/ensayo`: `node ensayo-postgrest.cjs`. Pide la URL del proyecto de ensayo, la clave anon (sin eco) y la frase `ENSAYAR EN PROYECTO SEPARADO`. Rechaza la URL de producción por su huella. | **Sí** (datos ficticios) | Michel, con autorización |
| 6 | Revisar la tabla en pantalla y el JSON en `ensayo/resultados/` (sin la clave). Esperado: todas las comprobaciones correctas (28 en el ensayo local del guion). | No | Michel y Claude |
| 7 | Probar el dashboard contra el ensayo: copiar `dashboard_lacava.html` a una carpeta local, cambiar **solo** las líneas `var SB=` y `var SK=` por la URL y la clave del ensayo, y abrirla desde un servidor local. **No publicar esa copia.** Recorrer Cotizaciones: alta de cliente, conversión de contado, transferencia, crédito sin y con abono, corte de red al confirmar (modo avión) y **Reintentar**, y dos pestañas a la vez. | **Sí** (datos ficticios) | Michel |
| 8 | Reversión sin operaciones: ejecutar un VERIFICAR, `HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql` y otro VERIFICAR (`NO_INSTALADO`, sin registro). Reinstalar. | **Sí** | Michel, con autorización |
| 9 | Reversión con operaciones (después de los pasos 5 y 7): ejecutar el REVERTIR. Esperado: aviso "se CONSERVO … operaciones", la tabla sigue con sus filas y sin privilegios para anon. VERIFICAR: `NO_INSTALADO` + `REGISTRO\|operaciones=N`. Reinstalar y repetir en el dashboard una conversión ya hecha: debe devolver la misma venta (`repetida`). | **Sí** | Michel, con autorización |

## Criterios de aprobación

1. La instalación termina en `COMMIT` con el rol real `postgres` (propiedad `cotconv_ejecutor`, `search_path` fijo) y el VERIFICAR no da ningún `ERROR\|`.
2. `anon` y `authenticated` reciben **401/403** al leer, insertar, modificar o borrar el registro.
3. Todas las comprobaciones del guion salen correctas, incluido que PostgREST devuelve `CV…` con HTTP 400 y el mensaje en español.
4. El dashboard completa los pagos, el corte de red con **Reintentar** (sin duplicar) y las dos pestañas (una sola venta).
5. Tras eliminar una venta convertida, el reintento responde que ya estaba registrada y **no** recrea la venta ni descuenta inventario.
6. La reversión conserva el registro cuando hay operaciones.

## Qué no cubre este ensayo

- Carga ni concurrencia real de varios locales.
- El aislamiento entre licencias (H1): `p_id_licencia` sigue siendo un dato del navegador.
- Realtime, caja ni reportes de producción.
- El comportamiento exacto de un esquema distinto al de producción, si se usó el esquema mínimo.

## Después del ensayo (producción: autorización aparte)

1. Lectura de solo lectura en producción: VERIFICAR (esperado `NO_INSTALADO`) y comprobar que no hay cotizaciones con `estado='convertida'` y `venta_id` nulo.
2. Instalar el SQL.
3. VERIFICAR (esperado `INSTALADO`, sin `ERROR\|`).
4. Publicar el frontend.
5. Prueba supervisada: un cliente nuevo, una conversión de contado y una de crédito.

**Vuelta atrás:** primero el frontend anterior (Netlify) y después el REVERTIR (ver el informe).
