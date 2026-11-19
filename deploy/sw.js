/* Service Worker - La Cava Oficial v2 (actualizacion coordinada con la pagina)
   Reglas:
   - La pagina (el "shell") se guarda COMPLETA al instalar y no cambia hasta que se instale otra version: lo que el usuario
     esta usando nunca se sustituye por debajo.
   - Una version nueva queda en ESPERA; solo pasa a activa cuando la pagina lo pide ("lacava-activar") tras una accion del usuario.
   - Este archivo NUNCA recarga ni navega ninguna pestana.
   - BUILD lo sella scripts/sellar-version.cjs (coincide con APP_BUILD de la pagina). No editar a mano. */
var BUILD = '622b33bb2ffb';
var CACHE = 'lacava-b-' + BUILD;
var SHELL = ['/', '/index.html', '/dashboard_lacava.html'];
var OPCIONALES = [
  '/manifest.json',
  '/icon-192.png',
  'https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap'
];

self.addEventListener('install', function(e){
  e.waitUntil((async function(){
    /* Si hay cachas de la version anterior (lacava-v1/v2), la pagina abierta NO sabe mostrar el aviso: se activa ya (como antes).
       Las siguientes versiones esperan a que el usuario pulse Actualizar. */
    var claves = await caches.keys();
    var heredaDeSinAviso = claves.some(function(k){ return /^lacava-v\d+$/.test(k); });

    /* La pagina se baja de la red SIN la cache HTTP y debe ser la de ESTE sello; si no, la instalacion falla y se reintenta
       (asi nunca queda una pagina de una version con un service worker de otra). */
    var r = await fetch('/', { cache: 'reload' });
    var tipo = r.headers.get('content-type') || '';
    if (r.status !== 200 || tipo.indexOf('text/html') < 0) throw new Error('shell no valido: ' + r.status);
    var texto = await r.clone().text();
    if (texto.indexOf("APP_BUILD='" + BUILD + "'") < 0) throw new Error('el shell publicado no corresponde a este service worker');

    var c = await caches.open(CACHE);
    await Promise.all(SHELL.map(function(u){ return c.put(u, r.clone()); }));
    await Promise.all(OPCIONALES.map(function(u){ return c.add(u).catch(function(){}); }));
    if (heredaDeSinAviso) self.skipWaiting();
  })());
});

self.addEventListener('activate', function(e){
  e.waitUntil((async function(){
    var claves = await caches.keys();
    await Promise.all(claves.filter(function(k){ return k.indexOf('lacava-') === 0 && k !== CACHE; }).map(function(k){ return caches.delete(k); }));
    await self.clients.claim();   /* la primera instalacion controla la pagina que ya esta abierta; no recarga nada */
  })());
});

self.addEventListener('message', function(e){
  var d = e.data || {};
  if (d.tipo === 'lacava-version') {
    var respuesta = { tipo: 'lacava-version', build: BUILD };
    if (e.ports && e.ports[0]) e.ports[0].postMessage(respuesta);
    else if (e.source) e.source.postMessage(respuesta);
  } else if (d.tipo === 'lacava-activar') {
    self.skipWaiting();           /* solo cuando la pagina lo pide tras una accion del usuario */
  }
});

self.addEventListener('fetch', function(e){
  if (e.request.method !== 'GET') return;
  var url = new URL(e.request.url);
  var mismoOrigen = url.origin === self.location.origin;
  var fuentes = url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com';
  if (!mismoOrigen && !fuentes) return;            /* Supabase siempre en red */
  if (mismoOrigen && url.pathname === '/sw.js') return;

  /* La pagina: siempre la guardada de esta version (inmutable); la red solo si falta. */
  if (mismoOrigen && e.request.mode === 'navigate' && SHELL.indexOf(url.pathname) >= 0) {
    e.respondWith(caches.open(CACHE).then(function(c){
      return c.match(url.pathname).then(function(r){ return r || fetch(e.request); });
    }));
    return;
  }

  /* Resto (iconos, manifiesto, catalogo, fuentes): guardado primero y se renueva en segundo plano. */
  e.respondWith(caches.open(CACHE).then(function(c){
    return c.match(e.request).then(function(cached){
      var red = fetch(e.request).then(function(res){
        if (res && res.status === 200) c.put(e.request, res.clone());
        return res;
      }).catch(function(){ return cached; });
      return cached || red;
    });
  }));
});
