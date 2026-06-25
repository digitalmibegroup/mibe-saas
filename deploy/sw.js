/* Service Worker - La Cava Oficial v1.0 */
var CACHE = 'lacava-v1';
var ASSETS = [
  '/',
  '/index.html',
  'https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap'
];

self.addEventListener('install', function(e){
  e.waitUntil(
    caches.open(CACHE).then(function(c){
      return c.addAll(ASSETS).catch(function(){return;});
    })
  );
  self.skipWaiting();
});

self.addEventListener('activate', function(e){
  e.waitUntil(
    caches.keys().then(function(keys){
      return Promise.all(keys.filter(function(k){return k!==CACHE;}).map(function(k){return caches.delete(k);}));
    })
  );
  self.clients.claim();
});

self.addEventListener('fetch', function(e){
  /* Solo cachea solicitudes GET y del mismo origen o fuentes conocidas */
  if(e.request.method !== 'GET') return;
  var url = new URL(e.request.url);
  var isSameOrigin = url.origin === self.location.origin;
  var isFonts = url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com';

  if(!isSameOrigin && !isFonts) return; /* Supabase siempre en red */

  e.respondWith(
    caches.match(e.request).then(function(cached){
      var network = fetch(e.request).then(function(res){
        if(res && res.status === 200 && (isSameOrigin || isFonts)){
          var clone = res.clone();
          caches.open(CACHE).then(function(c){c.put(e.request, clone);});
        }
        return res;
      }).catch(function(){return cached;});
      return cached || network;
    })
  );
});
