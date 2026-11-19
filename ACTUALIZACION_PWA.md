# Aviso de actualización de La Cava (PWA)

Estado: implementado y probado en local; **sin commit ni publicación** (pendiente de auditoría). No toca la base de datos.
Parte del `main` publicado con el hotfix `b502f93`.

## Qué hace el usuario

- Cuando hay una versión nueva, aparece un aviso fijo: «Hay una nueva versión disponible. Guarda lo que estás haciendo y pulsa Actualizar.»
  con los botones **Actualizar** y **Más tarde**.
- **Actualizar** carga la versión nueva con **una sola recarga**. Es la única forma: nada recarga la pantalla solo.
- **Más tarde** oculta el aviso y deja una pastilla pequeña «Actualización disponible» en la esquina que lo recupera. Sigue aplazado si se recarga a mano en la misma sesión.
- Si hay datos escritos y sin guardar, antes de recargar avisa con la lista («Sin guardar: …») y ofrece **Volver** o **Actualizar y descartar**.
- Si hay un guardado o una conversión de cotización en curso, el botón **Actualizar** queda bloqueado («Hay un guardado en curso. Espera a que termine para actualizar.») y se libera solo 1,5 s después de terminar.
- No se muestra en la primera instalación ni sin conexión (al volver la conexión reaparece).
- Varias pestañas: actualizar en una **no** recarga las demás ni borra lo que tengan escrito. Las otras muestran «Ya se actualizó en otra ventana; esta sigue con la versión anterior» y deciden ellas.

## Cómo funciona (service worker + página)

Antes el service worker (`lacava-v2`) hacía `skipWaiting`, `clients.claim` y respondía «guardado primero y se renueva después». Por eso la página abierta
quedaba atrás sin avisar, y hacían falta dos cargas para ver lo nuevo.

Ahora:

1. **Sello de versión.** `scripts/sellar-version.cjs` calcula un sello de 12 caracteres del contenido de la página **y** de `sw.js` y lo escribe en
   `APP_BUILD` (página) y `BUILD` (`deploy/sw.js`). Cualquier cambio en cualquiera de los dos archivos cambia el sello.
2. **La página es inmutable por versión.** Al instalarse, `sw.js` baja `/` de la red sin caché HTTP, comprueba que lleva **su** sello y la guarda
   en `lacava-b-<sello>`. Las navegaciones se sirven siempre de esa copia; lo que se está usando no cambia por debajo.
   Si la página publicada no lleva el sello del service worker (despliegue a medias), la instalación falla y se reintenta: no se avisa ni se rompe nada.
3. **La versión nueva espera.** No hay `skipWaiting` al instalar. La página detecta la versión en espera, le pregunta su sello (canal de mensajes) y,
   si es distinto de su `APP_BUILD`, muestra el aviso.
4. **Actualizar.** La página comprueba escrituras en curso y datos sin guardar; después envía `lacava-activar` al service worker en espera
   (`skipWaiting`), y al cambiar el controlador **solo la pestaña que lo pidió** recarga (una vez, y solo cuando no hay escrituras). Si en 8 s no cambia el controlador,
   lo dice y no recarga. No hay bucles: la recarga solo ocurre tras un clic.
5. **Detección activa.** La página revisa `reg.update()` al cargar, cada 10 min con la pestaña visible, al volver a primer plano (si pasaron más de 2 min) y al recuperar la conexión.
6. **Operación completa (no solo peticiones).** "Actualizar" queda bloqueado mientras haya **cualquiera** de estos indicadores, y se libera 1,5 s después de que todos terminen. **No hay límite de tiempo:** una operación activa bloquea hasta que termina; si pasan más de 120 s solo cambia el mensaje («El guardado está tardando más de lo normal y sigue en curso…»). El tiempo transcurrido nunca se toma como señal de que terminó:
   - **Funciones de guardado seguidas de principio a fin.** Al cargar, la página localiza las funciones `async` de nivel superior que escriben (`method:'POST'|'PATCH'|'PUT'|'DELETE'` o `/rpc/`) y las que llaman a alguna de ellas
     (75 hoy: `doVenta`, `guardarCompra`, `recibirCompra`, `guardarEdicionCompra`, `confirmarAbonoModal`, `registrarAbonoCarteraSB`, `confirmarConversionCot`, `guardarGasto`, `eliminarVenta`…) y las envuelve para contar la operación
     desde que empieza hasta que termina su promesa: **también entre peticiones y con pausas de cualquier duración**. No se modifica el cuerpo de ninguna función de la aplicación.
   - **Peticiones que modifican datos** (POST/PATCH/PUT/DELETE, incluidas las RPC), como respaldo para escrituras que no pasan por esas funciones.
   - **Los indicadores que la aplicación ya tiene:** `_cotEnProceso`, `_convCot.fase==='guardando'` y los botones **deshabilitados con texto de progreso** («Guardando...», «Procesando...», «Generando...»…; la convención del código).
     Un botón deshabilitado por validación (sin texto de progreso) no cuenta.
   - Si una operación se cuelga de verdad, el usuario puede recargar a mano (F5); el aviso no lo hará por él.
   - Mientras se aplica la actualización (≈1 s) un velo transparente impide iniciar **nuevas** operaciones desde la pantalla; la recarga solo ocurre tras dos comprobaciones seguidas sin operaciones.
7. **Datos sin guardar.** Se vigilan los campos de **datos** que el usuario editó (eventos de entrada de confianza): texto/número/teléfono/correo/URL, áreas de texto, **selectores, fechas (y hora/mes), casillas y opciones**
   (de un grupo de opciones se informa la elegida). Un campo cuenta mientras esté **visible** y su valor sea **distinto del que tenía al empezar a editarlo**: escribir y borrar, o cambiar y volver al valor inicial, no cuenta.
   - **Filtros fuera:** no cuentan los campos con `filtro`, `buscar`, `desde`, `hasta`, `periodo`, `rango`, `orden` en su id/nombre/placeholder, ni los dentro de contenedores `*controls*`/`*filter*`/`*filtro*` (listados y reportes),
     ni los selectores para elegir una línea que luego se agrega con un botón (`compraAddProd`, `compraAddTipo`, `editVentaProdSel`…), ni las casillas de opciones del POS (las cubre el carrito).
   - **También cuentan** el carrito de venta, la compra en curso (`itemsCompra`) y las líneas del inventario inicial y del traslado mientras su ventana está abierta.
   - **Ventas y cotizaciones abiertas para edición:** sus líneas (productos, cantidades, precios y descuentos) se comparan con las del estado inicial, tomado la primera vez que se ve la ventana abierta (siempre antes de la primera acción del usuario). Abrir sin editar, o volver a lo inicial (p. ej. +1 y −1, o agregar y quitar un producto nuevo), no avisa.
   - **Cotización nueva (aún sin guardar):** su estado inicial es «sin líneas». Agregar productos avisa aunque no cambie ningún campo de texto («cotización nueva con productos sin guardar»); quitarlas todas vuelve al estado inicial. Guardar con éxito o cancelar cierra la ventana y quita la advertencia; un guardado fallido la conserva.
   - **Nada se marca como guardado por haber terminado una función.** Cancelar o guardar con éxito cierra/oculta el formulario (o la aplicación lo deja en su valor inicial) y entonces deja de contar (comprobado cada segundo y tras cada clic).
     Si el guardado falla o no se puede confirmar, el formulario sigue abierto y el cambio sigue contando. Es preferible una advertencia de más a permitir descartar datos sin avisar. **«Volver»** no toca ningún valor.

### Transición desde el service worker publicado hoy (`lacava-v2`)

El service worker actual no sabe mostrar el aviso. Por eso `sw.js` nuevo, al detectar cachés `lacava-vN`, se activa en cuanto se instala (como hasta ahora). Efecto:
la página abierta no se toca ni se recarga; la **siguiente** carga ya trae la versión nueva (antes hacían falta dos). A partir de ahí, las versiones siguientes esperan al botón.
Probado con los archivos reales del commit `b502f93`.

## Limitaciones conocidas

- **Escrituras de fondo en la ventana de recarga.** Entre la decisión de recargar y el cambio real de página pasan de 100 ms a 1 s. Una escritura iniciada **por la propia aplicación** (temporizador, sincronización) justo en esa ventana se interrumpiría; las acciones del usuario están bloqueadas por el velo. No se puede cancelar la recarga sin abortar las peticiones en vuelo.
- **Funciones capturadas antes de envolverlas.** Si el código guarda una referencia a una función de guardado antes de la carga completa (p. ej. `addEventListener('click', guardarX)`), esa llamada no se sigue; quedan los demás indicadores (botón «Guardando...», peticiones). Los `onclick="..."` del HTML sí se siguen.
- **Funciones sin escritura propia pero con pasos largos** (p. ej. esperas con `setTimeout` sin peticiones) y que no llamen a ninguna función que escriba, no se siguen, salvo que usen el botón «Guardando...» o `_cotEnProceso`.
- **Cambios que no son datos de formulario:** se detectan las líneas de ventas y cotizaciones abiertas para edición (ver 7). Tras guardar con éxito un formulario que no se cierra (p. ej. Gastos), la fecha y la categoría que la aplicación deja puestas siguen contando como cambios y el aviso puede advertirlas de más («Actualizar y descartar» sigue disponible). Los campos de precio no editables de las ventas solo se cubren por la cantidad de sus líneas.
- **Activación diferida del service worker.** Si el navegador no activa la versión nueva en 4 s se vuelve a pedir (hasta 3 veces); si aun así no responde, se avisa («No se pudo aplicar la actualización…») y no se recarga. Se observó en pruebas que una petición iniciada en la **misma tarea** que la orden de activar puede dejar la activación en espera; desde la pantalla no puede ocurrir porque el botón está bloqueado mientras haya operaciones.

## Regla de despliegue (obligatoria)

Cada vez que cambie `dashboard_lacava.html` o `deploy/sw.js`, antes del commit:

```bash
node scripts/sellar-version.cjs            # sella y copia la página a deploy/index.html y deploy/dashboard_lacava.html
node scripts/sellar-version.cjs --verificar
node --test tests/aviso-actualizacion/
```

Si se olvida, la prueba «revisión del código» falla (el sello no coincide o las copias difieren). Si llegara a publicarse sin sellar, la instalación del service worker
fallaría y los usuarios seguirían con la versión anterior (sin romperse), con el error en la consola.

## Vuelta atrás

`git revert` del commit y push: el service worker anterior (`lacava-v2`) vuelve a instalarse, borra las cachés `lacava-b-*` y las páginas abiertas con el aviso no muestran
avisos falsos (el service worker antiguo no responde a la pregunta de versión).

## Pruebas

`tests/aviso-actualizacion/` (ver su `LEEME.md`): 24 pruebas en un Chrome/Edge real sin cabeza, escritorio (1366×768) y móvil (390×844), con los archivos reales de `deploy/`
servidos en varias versiones. Nada sale a internet (Supabase se simula y el resto se bloquea).
