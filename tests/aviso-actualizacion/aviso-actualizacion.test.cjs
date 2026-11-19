'use strict';
/* Pruebas del aviso de actualizacion en un navegador real (Chrome/Edge sin cabeza), con los archivos reales de deploy/ servidos
   localmente en varias versiones. Escritorio y movil. Nada sale a internet: Supabase se simula y el resto se bloquea.
   Ejecutar: node --test tests/aviso-actualizacion/      (capturas en LACAVA_EVIDENCIA, por defecto ~/LaCava-evidencia-local/aviso-actualizacion) */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { lanzar, sleep } = require('./cdp.cjs');
const { crear } = require('./servidor-versiones.cjs');
const { preparar } = require('./versiones.cjs');

const EVIDENCIA = process.env.LACAVA_EVIDENCIA || path.join(os.homedir(), 'LaCava-evidencia-local', 'aviso-actualizacion');
const TEXTO = 'Hay una nueva versión disponible. Guarda lo que estás haciendo y pulsa Actualizar.';
let nav = null, srv = null, base = null, V = null;
const SKIP = (() => { try { require('./cdp.cjs'); } catch { return 'sin cliente'; } return fs.existsSync('C:/Program Files/Google/Chrome/Application/chrome.exe') || fs.existsSync('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe') || !!process.env.LACAVA_NAVEGADOR ? false : 'no hay Chrome ni Edge'; })();

before(async () => {
  if (SKIP) return;
  V = preparar();
  srv = crear(V.dirs, 'v1'); base = await srv.iniciar();
  nav = await lanzar();
});
after(async () => { if (nav) await nav.cerrar(); if (srv) await srv.cerrar(); if (V) V.limpiar(); });

/* ---- ayudas ---- */
const js = {
  banner: "(function(){var e=document.getElementById('lcUpd');return !!e&&getComputedStyle(e).display!=='none';})()",
  punto: "(function(){var e=document.getElementById('lcUpdPunto');return !!e&&getComputedStyle(e).display!=='none';})()",
  ok: "document.querySelector('#lcUpd .lcu-ok')", no: "document.querySelector('#lcUpd .lcu-no')"
};
const estado = p => p.evaluar('__lcUpd.estado()');
const titulo = p => p.evaluar('document.title');
const textoBanner = p => p.evaluar("document.getElementById('lcUpd').innerText");
const caches = p => p.evaluar('caches.keys()');
async function sesion(opciones, version) {
  srv.cambiar(version || 'v1');
  const ctx = await nav.contexto();
  const p = await nav.pagina(ctx, opciones);
  await cargar(p);
  return { ctx, p };
}
async function cargar(p) {
  await p.ir(base + '/');
  await p.esperar("!!navigator.serviceWorker.controller&&!!document.getElementById('app')&&getComputedStyle(document.getElementById('app')).display==='flex'", 45000, 'aplicacion con service worker');
  const t0 = Date.now();
  while (!p.consola.some(l => l.indexOf('[SW] Registrado') >= 0) && Date.now() - t0 < 10000) await sleep(100);
  await p.evaluar("document.getElementById('modalCajaOverlay').style.display='none'");   /* aviso de caja de la aplicacion: no es parte de la prueba */
}
async function esperarBanner(p, ms) { await p.esperar(js.banner, ms || 20000, 'aviso visible'); }
async function hayNueva(p) { srv.cambiar('v2'); await p.evaluar('__lcUpd.revisar()'); await esperarBanner(p); }
const cerrar = async s => { await s.p.cerrar(); await nav.cerrarContexto(s.ctx); };
async function abrirProveedor(p) { await p.evaluar("document.getElementById('modalCajaOverlay').style.display='none';abrirModalProveedor();true"); await sleep(700); }
const sw = n => path.join(EVIDENCIA, n);
const opciones = { timeout: 120000, skip: SKIP };

test('primera instalacion: se instala, controla la pagina y NO muestra aviso ni recarga', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; const n0 = p.navegaciones;
    await p.evaluar('window.__marca=123');
    await sleep(2500);
    const e = await estado(p);
    assert.equal(e.pendiente, null); assert.equal(e.controlador, true); assert.equal(e.build, V.sello1);
    assert.equal(await p.evaluar(js.banner), false); assert.equal(await p.evaluar(js.punto), false);
    assert.equal(await p.evaluar('window.__marca'), 123, 'la pagina no se recargo');
    assert.equal(p.navegaciones, n0);
    assert.deepEqual(await caches(p), ['lacava-b-' + V.sello1]);
    assert.deepEqual(p.externas, [], 'nada salio a internet');
    await p.captura(sw('01-primera-instalacion-escritorio.png'));
  } finally { await cerrar(s); }
});

test('transicion desde el service worker publicado hoy (lacava-v2): se activa sin recargar y una sola recarga entrega la version nueva', opciones, async t => {
  if (!V.dirs.publicada) return t.skip('el commit publicado (' + require('./versiones.cjs').COMMIT_PUBLICADO + ') no esta disponible en este repositorio');
  const s = await sesion({}, 'publicada');
  try {
    const { p } = s;
    assert.deepEqual(await caches(p), ['lacava-v2'], 'el service worker publicado usa lacava-v2');
    assert.equal(await p.evaluar("typeof APP_BUILD"), 'undefined', 'la pagina publicada no tiene aviso');
    await p.evaluar('window.__marca=77'); const n0 = p.navegaciones;
    srv.cambiar('v1');
    await p.evaluar("navigator.serviceWorker.getRegistration().then(function(r){return r.update();}).then(function(){return true;})");
    await p.esperar("caches.keys().then(function(k){return k.length===1&&k[0]==='lacava-b-" + V.sello1 + "';})", 20000, 'cache nueva activa y lacava-v2 borrada');
    assert.equal(await p.evaluar('window.__marca'), 77, 'la pagina abierta no se recargo sola');
    assert.equal(p.navegaciones, n0);
    assert.equal(await p.evaluar("document.getElementById('lcUpd')"), null, 'la pagina vieja no puede mostrar el aviso');
    await p.recargar();
    assert.equal(p.navegaciones, n0 + 1, 'una sola recarga');
    await p.esperar("typeof APP_BUILD==='string'", 10000);
    assert.equal(await p.evaluar('APP_BUILD'), V.sello1, 'la primera recarga ya entrega la version nueva');
    assert.equal(await p.evaluar(js.banner), false);
    assert.deepEqual(await caches(p), ['lacava-b-' + V.sello1]);
    /* y a partir de ahi el aviso funciona */
    await p.evaluar("document.getElementById('modalCajaOverlay')&&(document.getElementById('modalCajaOverlay').style.display='none')");
    await p.esperar("!!navigator.serviceWorker.controller", 10000);
    await hayNueva(p);
    assert.equal(await textoBanner(p).then(t => t.split('\n')[0]), TEXTO);
  } finally { await cerrar(s); }
});

test('deteccion: aparece el aviso persistente con el texto y los botones pedidos, sin recargar y sin cambiar la pantalla en uso', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await p.evaluar('window.__marca=1'); const n0 = p.navegaciones;
    await hayNueva(p);
    const t = await textoBanner(p);
    assert.equal(t.split('\n')[0], TEXTO);
    assert.deepEqual(await p.evaluar("Array.prototype.map.call(document.querySelectorAll('#lcUpd button'),function(b){return b.textContent;})"), ['Actualizar', 'Más tarde']);
    assert.equal(await p.evaluar("document.getElementById('lcUpd').getAttribute('role')"), 'alert');
    await sleep(3000);
    assert.equal(await p.evaluar('window.__marca'), 1); assert.equal(p.navegaciones, n0, 'no se recargo');
    assert.equal(await titulo(p), 'La Cava Licorera', 'la pantalla en uso sigue con la version anterior');
    assert.equal(await p.evaluar("navigator.serviceWorker.getRegistration().then(function(r){return !!r.waiting;})"), true, 'la version nueva espera');
    assert.equal(await p.evaluar(js.banner), true, 'persiste');
    await p.captura(sw('02-aviso-escritorio.png'));
  } finally { await cerrar(s); }
});

test('aplazamiento: "Mas tarde" oculta el aviso y deja un indicador discreto que lo recupera; sobrevive a una recarga manual', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p);
    await p.clic('#lcUpd .lcu-no');
    await p.esperar("!(" + js.banner + ")", 5000);
    assert.equal(await p.evaluar(js.punto), true);
    assert.equal(await p.evaluar("document.getElementById('lcUpdPunto').innerText"), 'Actualización disponible');
    const r = await p.centro('#lcUpdPunto'); assert.ok(r.w < 220 && r.h < 40, 'discreto: ' + r.w + 'x' + r.h);
    await p.captura(sw('03-indicador-escritorio.png'));
    await p.clic('#lcUpdPunto');
    await p.esperar(js.banner, 5000); assert.equal(await p.evaluar(js.punto), false);
    await p.clic('#lcUpd .lcu-no');
    await p.esperar(js.punto, 5000);
    await p.recargar();   /* recarga manual del usuario: la version nueva sigue esperando */
    await p.esperar("!!window.__lcUpd&&!!__lcUpd.estado().pendiente", 20000, 'pendiente tras recargar');
    assert.equal(await p.evaluar(js.banner), false, 'tras recargar sigue aplazado en esta sesion');
    assert.equal(await p.evaluar(js.punto), true);
    assert.equal(await titulo(p), 'La Cava Licorera');
  } finally { await cerrar(s); }
});

test('actualizacion voluntaria: un clic = una sola recarga que ya muestra la version nueva, sin bucle ni segunda recarga', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p); const n0 = p.navegaciones;
    await p.clic('#lcUpd .lcu-ok'); await p.clic('#lcUpd .lcu-ok').catch(() => { });   /* segundo clic rapido: no debe duplicar */
    await p.esperar("document.title.indexOf('[v2]')===0", 20000, 'version nueva');
    await p.esperar("typeof APP_BUILD==='string'&&!!navigator.serviceWorker.controller", 10000);
    assert.equal(await p.evaluar('APP_BUILD'), V.sello2);
    await sleep(4000);
    assert.equal(p.navegaciones, n0 + 1, 'exactamente una recarga');
    assert.equal(await p.evaluar(js.banner), false); assert.equal(await p.evaluar(js.punto), false);
    assert.deepEqual(await caches(p), ['lacava-b-' + V.sello2], 'la cache anterior se elimino');
    assert.equal((await estado(p)).pendiente, null);
  } finally { await cerrar(s); }
});

test('formularios abiertos: advierte con lo que no se guardo, "Volver" conserva todo y solo "Actualizar y descartar" recarga', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p); await p.evaluar('window.__marca=5'); const n0 = p.navegaciones;
    /* 1) un formulario abierto pero vacio no advierte (se comprueba sin recargar) */
    await abrirProveedor(p);
    assert.deepEqual((await estado(p)).sinGuardar, []);
    /* 2) escribir + borrar no cuenta; escribir en un formulario que luego se cierra tampoco */
    await p.escribir('#modalProvNombre', 'abc'); assert.equal((await estado(p)).sinGuardar.length, 1);
    await p.evaluar("document.getElementById('modalProvNombre').value='';true"); assert.deepEqual((await estado(p)).sinGuardar, []);
    await p.escribir('#modalProvNombre', 'Distribuidora Prueba'); await p.escribir('#modalProvWA', '3001234567');
    await p.evaluar('cerrarModalProveedor();true'); assert.deepEqual((await estado(p)).sinGuardar, [], 'un formulario cerrado no cuenta');
    /* 3) un campo de busqueda no cuenta; el carrito con productos si */
    await p.evaluar("var b=document.createElement('input');b.type='text';b.id='buscarTest';b.placeholder='Buscar producto';document.body.appendChild(b);true");
    await p.escribir('#buscarTest', 'ron'); assert.deepEqual((await estado(p)).sinGuardar, []);
    await p.evaluar("cart.push({id:'t1',nombre:'Ron',precio:1000,qty:1});true");
    assert.deepEqual((await estado(p)).sinGuardar, ['venta en curso con 1 producto']);
    await p.evaluar('cart.length=0;true');
    /* 4) con datos escritos y visibles: aviso, y Volver no recarga ni borra nada */
    await abrirProveedor(p);
    await p.escribir('#modalProvNombre', 'Distribuidora Prueba'); await p.escribir('#modalProvWA', '3001234567');
    await p.clic('#lcUpd .lcu-ok');
    await p.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar y descartar'", 5000, 'confirmacion');
    const t = await textoBanner(p);
    assert.match(t, /Hay datos sin guardar en esta pantalla/); assert.match(t, /Nombre/); assert.match(t, /WhatsApp/);
    await sleep(700); await p.captura(sw('04-confirmar-sin-guardar-escritorio.png'));
    await p.clic('#lcUpd .lcu-no');   /* Volver */
    await p.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar'", 5000);
    assert.equal(await p.evaluar("document.getElementById('modalProvNombre').value"), 'Distribuidora Prueba', 'lo escrito se conserva');
    assert.equal(await p.evaluar('window.__marca'), 5); assert.equal(p.navegaciones, n0);
    /* 5) Actualizar y descartar */
    await p.clic('#lcUpd .lcu-ok'); await p.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar y descartar'", 5000);
    await p.clic('#lcUpd .lcu-ok');
    await p.esperar("document.title.indexOf('[v2]')===0", 20000, 'version nueva');
    assert.equal(p.navegaciones, n0 + 1);
  } finally { await cerrar(s); }
});

test('guardado en curso: la actualizacion se bloquea mientras se guarda o se convierte y se libera al terminar', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p); await p.evaluar('window.__marca=9'); const n0 = p.navegaciones;
    await abrirProveedor(p);
    await p.escribir('#modalProvNombre', 'Proveedor en guardado');
    const liberar = p.retenerEscrituras();
    await p.clic('#modalProvBtnGuardar');                 /* guardado real de la aplicacion: la respuesta queda retenida */
    await p.esperar("__lcUpd.estado().operaciones>=1", 5000, 'escritura en curso');
    await p.esperar("document.querySelector('#lcUpd .lcu-ok').disabled===true", 5000, 'boton bloqueado');
    assert.match(await textoBanner(p), /Hay un guardado en curso\. Espera a que termine para actualizar\./);
    await sleep(700); await p.captura(sw('05-guardado-en-curso-escritorio.png'));
    await p.evaluar("document.querySelector('#lcUpd .lcu-ok').click();true");   /* un clic sobre el boton bloqueado no hace nada */
    await sleep(800); assert.equal(p.navegaciones, n0); assert.equal(await p.evaluar('window.__marca'), 9);
    liberar();
    await p.esperar("__lcUpd.estado().escrituras===0", 5000);
    assert.equal(await p.evaluar("document.querySelector('#lcUpd .lcu-ok').disabled"), true, 'sigue bloqueado el margen de seguridad de 1,5 s');
    await p.esperar("document.querySelector('#lcUpd .lcu-ok').disabled===false", 6000, 'boton liberado');
    assert.ok(p.supabase.indexOf('POST /rest/v1/proveedores') >= 0, 'el guardado se envio');
    /* una conversion de cotizacion en curso tambien bloquea */
    await p.evaluar("_cotEnProceso['prueba']=true;true");
    await p.esperar("document.querySelector('#lcUpd .lcu-ok').disabled===true", 5000, 'bloqueado por conversion');
    await p.evaluar("document.querySelector('#lcUpd .lcu-ok').click();true"); await sleep(600);
    assert.equal(p.navegaciones, n0, 'bloqueado: no recarga mientras convierte');
    await p.evaluar("delete _cotEnProceso['prueba'];true");
    await p.esperar("document.querySelector('#lcUpd .lcu-ok').disabled===false", 6000, 'liberado al terminar la conversion');
    await p.evaluar('cerrarModalProveedor();true');       /* el guardado ya termino: no queda nada sin guardar */
    await p.clic('#lcUpd .lcu-ok');
    await p.esperar("document.title.indexOf('[v2]')===0", 20000, 'version nueva');
  } finally { await cerrar(s); }
});

test('varias pestanas: actualizar en una NO recarga las otras ni borra lo escrito en ellas', opciones, async () => {
  srv.cambiar('v1');
  const ctx = await nav.contexto();
  const A = await nav.pagina(ctx), B = await nav.pagina(ctx);
  try {
    await cargar(A); await cargar(B);
    await A.evaluar('window.__marca="A"'); await B.evaluar('window.__marca="B"');
    await abrirProveedor(B); await B.escribir('#modalProvNombre', 'Texto en la otra pestana');
    const nA = A.navegaciones, nB = B.navegaciones;
    srv.cambiar('v2');
    await A.evaluar('__lcUpd.revisar()'); await B.evaluar('__lcUpd.revisar()');
    await esperarBanner(A); await esperarBanner(B);
    await A.clic('#lcUpd .lcu-ok');
    await A.esperar("document.title.indexOf('[v2]')===0", 20000, 'A actualizada');
    assert.equal(A.navegaciones, nA + 1);
    await B.esperar("__lcUpd.estado().pendiente&&__lcUpd.estado().pendiente.origen==='otra'", 15000, 'B sabe que se actualizo en otra ventana');
    assert.equal(await B.evaluar('window.__marca'), 'B', 'B no se recargo'); assert.equal(B.navegaciones, nB);
    assert.equal(await B.evaluar("document.getElementById('modalProvNombre').value"), 'Texto en la otra pestana', 'lo escrito en B sigue ahi');
    assert.equal(await titulo(B), 'La Cava Licorera', 'B sigue mostrando su version hasta que el usuario decida');
    assert.match(await textoBanner(B), /Ya se actualizó en otra ventana/);
    await B.captura(sw('06-otra-pestana-escritorio.png'));
    await sleep(2500); assert.equal(B.navegaciones, nB, 'B sigue sin recargarse');
    await B.clic('#lcUpd .lcu-ok');                      /* B tiene datos: advierte */
    await B.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar y descartar'", 5000);
    await B.clic('#lcUpd .lcu-no');
    assert.equal(await B.evaluar("document.getElementById('modalProvNombre').value"), 'Texto en la otra pestana');
    await B.clic('#lcUpd .lcu-ok'); await B.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar y descartar'", 5000);
    await B.clic('#lcUpd .lcu-ok');
    await B.esperar("document.title.indexOf('[v2]')===0", 20000, 'B actualizada por decision del usuario');
    assert.equal(B.navegaciones, nB + 1);
  } finally { await A.cerrar(); await B.cerrar(); await nav.cerrarContexto(ctx); }
});

test('desconexion: sin conexion no se muestra el aviso (ni se consulta la red) y la aplicacion sigue abriendo desde la copia guardada; al volver, reaparece', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p);
    await p.sinConexion(true);
    await p.esperar("!(" + js.banner + ")&&!(" + js.punto + ")", 5000, 'aviso oculto sin conexion');
    assert.equal((await estado(p)).pendiente.build, V.sello2, 'la version nueva sigue pendiente');
    await p.captura(sw('07-sin-conexion-escritorio.png'));
    const antes = srv.registro.length;
    await p.evaluar('__lcUpd.revisar()'); await sleep(800);
    assert.equal(srv.registro.length, antes, 'no se consulto el servidor sin conexion');
    await p.recargar();                                  /* sin red: la pagina sale del service worker */
    assert.equal(await titulo(p), 'La Cava Licorera');
    await p.esperar("!!window.__lcUpd&&!!__lcUpd.estado().pendiente", 20000, 'pendiente detectado de nuevo (sin red)');
    assert.equal(await p.evaluar(js.banner), false); assert.equal(await p.evaluar(js.punto), false);
    await p.sinConexion(false);
    await p.esperar(js.banner, 10000, 'reaparece al volver la conexion');
  } finally { await cerrar(s); }
});

test('despliegue a medias (pagina de una version con service worker de otra): no se instala, no se avisa y la aplicacion sigue; al completarse el despliegue, avisa', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s;
    srv.cambiar('mixta'); await p.evaluar('__lcUpd.revisar()'); await sleep(3000);
    assert.equal(await p.evaluar(js.banner), false);
    assert.equal(await p.evaluar("navigator.serviceWorker.getRegistration().then(function(r){return !r.waiting&&!r.installing;})"), true, 'el service worker incoherente no queda instalado');
    assert.deepEqual(await caches(p), ['lacava-b-' + V.sello1]);
    assert.equal(await titulo(p), 'La Cava Licorera');
    await hayNueva(p);   /* ahora si: version completa */
  } finally { await cerrar(s); }
});

test('vuelta atras: si se vuelve a publicar el service worker anterior (lacava-v2), se instala, limpia las cachés nuevas y la pagina abierta no muestra avisos falsos', opciones, async t => {
  if (!V.dirs.publicada) return t.skip('el commit publicado no esta disponible');
  const s = await sesion();
  try {
    const { p } = s; await p.evaluar('window.__marca=3'); const n0 = p.navegaciones;
    srv.cambiar('publicada');
    const hasta = Date.now() + 40000;     /* el navegador puede tardar en revisar el service worker si la maquina esta ocupada: se insiste */
    for (;;) {
      await p.evaluar('__lcUpd.revisar()');
      const listo = await p.esperar("caches.keys().then(function(k){return k.length===1&&k[0]==='lacava-v2';})", 6000, 'service worker anterior activo').then(() => true, () => false);
      if (listo) break; if (Date.now() > hasta) throw new Error('tiempo agotado esperando el service worker anterior');
    }
    await sleep(2500);
    assert.equal(await p.evaluar(js.banner), false); assert.equal(await p.evaluar(js.punto), false);
    assert.equal((await estado(p)).pendiente, null);
    assert.equal(await p.evaluar('window.__marca'), 3); assert.equal(p.navegaciones, n0, 'no se recargo');
  } finally { await cerrar(s); }
});

test('movil: el aviso, la confirmacion, el guardado y el indicador caben en pantalla y se pueden tocar', opciones, async () => {
  const s = await sesion({ movil: true });
  try {
    const { p } = s; await hayNueva(p);
    const caja = async sel => p.evaluar("(function(){var e=document.querySelector(" + JSON.stringify(sel) + ");var r=e.getBoundingClientRect();var q=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);return{l:r.left,r:r.right,t:r.top,b:r.bottom,w:r.width,h:r.height,iw:innerWidth,ih:innerHeight,encima:!!q&&(q===e||e.contains(q)),sw:document.documentElement.scrollWidth};})()");
    let r = await caja('#lcUpd');
    assert.ok(r.l >= 0 && r.r <= r.iw && r.b <= r.ih && r.t >= 0, JSON.stringify(r)); assert.equal(r.iw, 390); assert.ok(r.encima, 'nada lo tapa'); assert.ok(r.sw <= r.iw, 'sin desplazamiento horizontal');
    for (const b of ['#lcUpd .lcu-ok', '#lcUpd .lcu-no']) { const c = await caja(b); assert.ok(c.h >= 40 && c.w >= 80, b + ' ' + c.w + 'x' + c.h); assert.ok(c.encima); }
    await p.captura(sw('m01-aviso-movil.png'));
    await abrirProveedor(p); await p.escribir('#modalProvNombre', 'Proveedor movil');
    await p.clic('#lcUpd .lcu-ok'); await p.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar y descartar'", 5000);
    r = await caja('#lcUpd'); assert.ok(r.l >= 0 && r.r <= r.iw && r.b <= r.ih, JSON.stringify(r));
    await sleep(700); await p.captura(sw('m02-confirmar-movil.png'));
    await p.clic('#lcUpd .lcu-no'); await p.evaluar('cerrarModalProveedor();true');
    await p.clic('#lcUpd .lcu-no');
    await p.esperar(js.punto, 5000);
    r = await caja('#lcUpdPunto'); assert.ok(r.l >= 0 && r.r <= r.iw && r.b <= r.ih && r.encima, JSON.stringify(r));
    await p.captura(sw('m03-indicador-movil.png'));
    await p.clic('#lcUpdPunto'); await p.esperar(js.banner, 5000);
    await abrirProveedor(p); await p.escribir('#modalProvNombre', 'Guardando movil');
    const liberar = p.retenerEscrituras(); await p.evaluar("document.getElementById('modalProvBtnGuardar').click();true");
    await p.esperar("document.querySelector('#lcUpd .lcu-ok').disabled===true", 5000);
    await sleep(700); await p.captura(sw('m04-guardado-en-curso-movil.png'));
    liberar(); await p.esperar("document.querySelector('#lcUpd .lcu-ok').disabled===false", 8000);
    const n0 = p.navegaciones; await p.clic('#lcUpd .lcu-ok');
    await p.esperar("document.title.indexOf('[v2]')===0", 20000, 'version nueva en movil');
    assert.equal(p.navegaciones, n0 + 1);
  } finally { await cerrar(s); }
});

test('el service worker y la pagina nunca recargan por su cuenta (revision del codigo)', { skip: false }, () => {
  const RAIZ = path.join(__dirname, '..', '..');
  const swSrc = fs.readFileSync(path.join(RAIZ, 'deploy', 'sw.js'), 'utf8');
  assert.doesNotMatch(swSrc, /\.navigate\(|location\.reload|\.reload\(/, 'sw.js no navega ni recarga');
  const html = fs.readFileSync(path.join(RAIZ, 'deploy', 'dashboard_lacava.html'), 'utf8');
  const ini = html.indexOf("var APP_BUILD='"), fin = html.indexOf('/* ---- KEEP-ALIVE');
  const modulo = html.slice(ini, fin);
  assert.equal((modulo.match(/location\.reload\(\)/g) || []).length, 1, 'una unica recarga, dentro de recargar()');
  assert.ok(modulo.indexOf('location.reload()') > modulo.indexOf('function recargar()'));
  assert.equal((modulo.match(/recargar\(\)/g) || []).length >= 2, true);
  const { estado: sello } = require('../../scripts/sellar-version.cjs');
  const e = sello(); assert.deepEqual(e.problemas, [], 'el sello de la pagina y del service worker coincide y las copias son identicas');
});
