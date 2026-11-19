# Pruebas del aviso de actualización

Sin dependencias (solo Node y Chrome o Edge instalados). Desde la raíz del repositorio:

```bash
node --test tests/aviso-actualizacion/
```

Variables opcionales: `LACAVA_NAVEGADOR` (ruta de Chrome/Edge), `LACAVA_EVIDENCIA` (carpeta de capturas; por defecto `~/LaCava-evidencia-local/aviso-actualizacion`),
`LACAVA_REV_PUBLICADA` (commit publicado para probar la transición; por defecto `b502f93`).

## Cómo funciona

- `versiones.cjs` arma las versiones con los archivos reales de `deploy/`: `publicada` (commit publicado, `lacava-v2`), `v1` (esta rama), `v2` (v1 con otro título y su propio sello) y
  `mixta` (página de v1 con el service worker de v2, un despliegue a medias).
- `servidor-versiones.cjs` imita a Netlify (`/` → `dashboard_lacava.html`, `Cache-Control: max-age=0, must-revalidate`) y permite cambiar de versión sin reiniciar, como un despliegue.
- `cdp.cjs` lanza Chrome/Edge sin cabeza con perfil temporal y **sin DNS externo**: solo `localhost`. Supabase se simula (licencia válida y listas vacías; las escrituras se pueden retener
  para simular un guardado lento) y todo lo demás se bloquea. Cada prueba usa un contexto limpio. Los avisos de caja de la propia aplicación se ocultan.

## Pruebas específicas (datos-y-operaciones.test.cjs)

- **Datos sin guardar:** modificar solo un selector, una fecha o una casilla/opción; los filtros (de gastos, compras, cotizaciones, cartera) no cuentan; cancelar (producto, proveedor) limpia el estado; **guardar NO marca nada como guardado por sí solo** (si el guardado falla todo sigue contando; si sale bien solo deja de contar lo que la aplicación limpia o cierra); Volver conserva los valores.
- **Ventas y cotizaciones abiertas para edición:** cantidades, precios, descuentos y productos agregados/quitados cuentan frente al estado inicial; abrir sin editar y volver a lo inicial no; un guardado fallido conserva el aviso.
- **Cotización nueva:** abrir vacía no avisa; agregar líneas sí (sin tocar ningún campo de texto); quitarlas todas vuelve al inicio; Volver conserva productos y cantidades; guardar con éxito o cancelar limpian; un guardado fallido conserva.
- **Operación completa:** funciones de guardado reales seguidas al cargar; operación con **pausa de 3,5 s sin ninguna petición** entre dos escrituras (Actualizar sigue bloqueado y no se puede actualizar durante la pausa: clic real, programático y tecla); clic en Actualizar justo antes de que la aplicación empiece a guardar (la recarga espera);
  y los indicadores propios de la aplicación (botón «Guardando...», `_cotEnProceso`, `_convCot.fase`).
- **Más de 120 s:** una operación que sigue activa pasado ese tiempo (escritura en vuelo, botón «Guardando...», función en una pausa) sigue bloqueando y solo avisa de la demora; se libera al terminar.

## Qué cubre

Primera instalación · transición desde `lacava-v2` · detección · aplazamiento (y recuperación, y recarga manual) · actualización voluntaria (una sola recarga, sin bucle) ·
formularios abiertos (vacío, escrito y borrado, cerrado, búsqueda, carrito, Volver, descartar) · guardado real en curso y conversión en curso · dos pestañas ·
desconexión (y arranque sin red desde la copia guardada) · despliegue a medias · móvil (cabe, se puede tocar, nada lo tapa, sin desplazamiento horizontal) ·
y una revisión de código: ni `sw.js` ni la página recargan por su cuenta (una sola llamada a `location.reload()`, dentro de `recargar()`) y el sello coincide.
