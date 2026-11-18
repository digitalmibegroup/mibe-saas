# Pruebas del hotfix "Convertir cotización en venta" (atómico)

Solo usan módulos de Node (sin `npm install`). Ejecutar desde la raíz del repositorio:

```bash
node --test tests/hotfix-cotizaciones/
```

## Requisitos del entorno
| Requisito | Para qué | Si falta |
|---|---|---|
| Node 22 o superior | todo (la prueba del service worker usa `WebSocket` global) | fallan |
| PostgreSQL 17 portable (carpeta `bin` con `initdb`, `pg_ctl`, `psql`), ruta en `LACAVA_PG_BIN` (por defecto `C:/Users/USUARIO/LaCava-herramientas/pg17-extraido/pgsql/bin`) | `pg/*.test.cjs` y `ensayo/*.test.cjs` | se **omiten** |
| Copia de integración v5/H1 (solo lectura), ruta en `LACAVA_INTEGRACION` | `ensayo/*.test.cjs` (base local con Compras v5 + H1) | se **omiten** |
| Chrome o Edge instalado | `service-worker/sw-actualizacion.cjs` (script, no `*.test`): `node tests/hotfix-cotizaciones/service-worker/sw-actualizacion.cjs` | no corre |
| El commit de producción previo al hotfix (`eacde3b`, o `LACAVA_REV_PUBLICADA`) en el historial del clon | reproducir el defecto de la versión publicada y probar la actualización del service worker v1 → v2 | esa prueba se omite |

## Archivos de la raíz que las pruebas leen (deben estar en el commit)
`dashboard_lacava.html`, `deploy/*`, `HOTFIX_COT_CONVERSION_ATOMICA.sql`, `..._REVERTIR.sql`, `..._VERIFICAR.sql`,
`HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql` (variante de staging, generada por `ensayo/generar-variante-staging-h1.cjs`),
`ANON_ENSAYO_STAGING_CAPTURA.sql`, `ANON_ENSAYO_STAGING_ABRIR.sql`, `ANON_ENSAYO_STAGING_RESTAURAR.sql`.

Los lanzadores de staging (`*.ps1`) no se prueban aquí: necesitan Docker y la contraseña de la base; su lógica SQL se ensaya en `ensayo/*.test.cjs`.
