'use strict';
/* Pruebas de "Ocultar / Volver a mostrar" productos del modulo Inventario, en un Chrome/Edge real (escritorio 1366x768 y movil 390x844) con los
   archivos reales de deploy/. Supabase se simula con una base EN MEMORIA con estado (inventario e inventario_bodega, con filtros eq. y PATCH
   condicionado como PostgREST); todo lo demas se bloquea. Datos ficticios. */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { lanzar, sleep } = require('../aviso-actualizacion/cdp.cjs');
const { crear } = require('../aviso-actualizacion/servidor-versiones.cjs');
const { preparar } = require('../aviso-actualizacion/versiones.cjs');

const RAIZ = path.join(__dirname, '..', '..');
const EVIDENCIA = process.env.LACAVA_EVIDENCIA || path.join(os.homedir(), 'LaCava-evidencia-local', 'inventario-ocultar');
const sw = n => path.join(EVIDENCIA, n);
let nav = null, srv = null, base = null, V = null;
const SKIP = (fs.existsSync('C:/Program Files/Google/Chrome/Application/chrome.exe') || fs.existsSync('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe') || !!process.env.LACAVA_NAVEGADOR) ? false : 'no hay Chrome ni Edge';
before(async () => { if (SKIP) return; V = preparar(); srv = crear(V.dirs, 'v1'); base = await srv.iniciar(); nav = await lanzar(); });
after(async () => { if (nav) await nav.cerrar(); if (srv) await srv.cerrar(); if (V) V.limpiar(); });
const opciones = { timeout: 120000, skip: SKIP };

/* ---------- base simulada con estado ---------- */
const prod = (id, nombre, extra) => Object.assign({ id, nombre, categoria: 'Licores', precio_venta: 10000, precio_costo: 6000, stock: 0, stock_min: 2, empaque: 'unidad', uds_empaque: 1, uds_sueltas: 0, imagen: null, oculto: false, id_licencia: 'lacava' }, extra);
const semilla = () => [
  prod('prod_aguila', 'Aguila 330'),                                                       /* sin existencias: se puede ocultar */
  prod('prod_corona', 'Corona 355', { stock: 5 }),                                         /* con stock */
  prod('prod_poker', 'Poker Six Pack', { empaque: 'sixpack', uds_empaque: 6, uds_sueltas: 3 }),   /* solo unidades sueltas */
  prod('prod_ron', 'Ron Medellin'),                                                        /* principal en cero, pero con stock en la bodega */
  prod('prod_vino', 'Vino Tinto', { oculto: true }),                                       /* ya oculto */
  prod('prod_whisky', 'Whisky Old', { stock: 2 })
];
function crearBase() {
  const db = {
    inv: semilla(), bod: [{ id: 'b1', id_licencia: 'lacava', id_bodega: 'bod1', prod_id: 'prod_ron', stock: 4, uds_sueltas: 0 }],
    escrituras: [], sinColumna: false, antesDePatch: null, fallar: false, fallarLimpieza: false,
    manejador(metodo, u, cuerpo) {
      const tabla = u.pathname === '/rest/v1/inventario' ? 'inv' : u.pathname === '/rest/v1/inventario_bodega' ? 'bod' : null;
      if (!tabla) return null;
      const filtros = [...u.searchParams].filter(([k, v]) => v.startsWith('eq.') && !['select', 'order', 'id_licencia', 'id_bodega'].includes(k));
      const coincide = f => filtros.every(([k, v]) => String(f[k]) === v.slice(3));
      const ver = f => { const c = Object.assign({}, f); if (db.sinColumna) delete c.oculto; return c; };
      if (metodo === 'GET') return { codigo: 200, cuerpo: db[tabla].filter(coincide).map(ver) };
      if (db.fallar) return { codigo: 500, cuerpo: { message: 'error simulado' } };
      db.escrituras.push({ metodo, tabla, filtros: Object.fromEntries(filtros.map(([k, v]) => [k, v.slice(3)])), cuerpo: cuerpo ? JSON.parse(cuerpo) : null });
      if (metodo === 'PATCH') {
        const b = JSON.parse(cuerpo || '{}');
        if (db.sinColumna && 'oculto' in b) return { codigo: 400, cuerpo: { code: 'PGRST204', message: "Could not find the 'oculto' column of 'inventario' in the schema cache" } };
        if (db.fallarLimpieza && b.oculto === false) return { codigo: 500, cuerpo: { message: 'error simulado en la limpieza' } };
        if (db.antesDePatch) { const h = db.antesDePatch; db.antesDePatch = null; h(db); }   /* otro dispositivo cambia algo justo antes de la escritura */
        const af = db[tabla].filter(coincide); af.forEach(f => Object.assign(f, b));
        return { codigo: 200, cuerpo: af.map(ver) };
      }
      return null;
    }
  };
  return db;
}
const fila = (db, id) => db.inv.find(f => f.id === id);
const escriturasOculto = (db, v) => db.escrituras.filter(e => e.tabla === 'inv' && e.cuerpo && 'oculto' in e.cuerpo && (v === undefined || e.cuerpo.oculto === v));

/* ---------- ayudas ---------- */
async function sesion(db, op) {
  const ctx = await nav.contexto(); const p = await nav.pagina(ctx, op || {});
  p.manejador = db.manejador; await p.ir(base + '/');
  await p.esperar("getComputedStyle(document.getElementById('app')).display==='flex'&&INVENTARIO.length>0", 45000, 'aplicacion con inventario');
  return { ctx, p };
}
const cerrar = async s => { await s.p.cerrar(); await nav.cerrarContexto(s.ctx); };
async function irInventario(p) {
  await p.evaluar("goView('inventario');true");
  await p.esperar("document.querySelectorAll('#invTableBody tr').length>0&&INV_BODEGA_CON_STOCK!==null", 15000, 'inventario cargado');
  await sleep(300);
}
const NOMBRES_JS = "Array.from(document.querySelectorAll('#invTableBody tr')).map(function(tr){var d=tr.cells[0]&&tr.cells[0].querySelector('div[style*=\"font-weight:600\"]');return d?d.textContent.trim():'';}).filter(Boolean)";
const nombres = p => p.evaluar(NOMBRES_JS);
const chip = p => p.evaluar("document.getElementById('invFbHidden').innerText.trim()");
const total = p => p.evaluar("document.getElementById('invStatTotal').textContent");
const toastTxt = p => p.evaluar("document.getElementById('toast').textContent");
const botones = (p, accion) => p.evaluar("Array.from(document.querySelectorAll('#invTableBody [data-accion=\"" + accion + "\"]')).map(function(b){return b.getAttribute('onclick').match(/'([^']+)'/)[1];})");
const ocultar = async (p, id) => { await p.evaluar("var t=document.getElementById('toast');t.classList.remove('s');t.textContent='';true"); await p.clic("#invTableBody [data-accion=\"ocultar\"][onclick*=\"'" + id + "'\"]"); };
const verOcultos = async p => { await p.clic('#invFbHidden'); await sleep(300); };
const iguales = (a, b) => assert.deepEqual([...a].sort(), [...b].sort());

/* ======================= escritorio ======================= */

test('OCULTAR y VOLVER A MOSTRAR: solo con existencias totales en cero; el producto queda intacto; vista "Ocultos"', opciones, async () => {
  const db = crearBase(); const s = await sesion(db);
  try {
    const { p } = s; await irInventario(p);
    iguales(await nombres(p), ['Aguila 330', 'Corona 355', 'Poker Six Pack', 'Ron Medellin', 'Whisky Old']);   /* el ya oculto (Vino) no aparece */
    assert.equal(await chip(p), '\u{1F441} Ocultos (1)'.replace('\u{1F441}', await p.evaluar("document.getElementById('invFbHidden').innerText.trim().split(' ')[0]")), 'el filtro Ocultos cuenta 1');
    assert.match(await chip(p), /Ocultos \(1\)/); assert.equal(await total(p), '5', 'el total no cuenta el oculto');
    /* "Ocultar" solo se ofrece con principal en cero y sin sueltas (la bodega se comprueba al pulsar) */
    iguales(await botones(p, 'ocultar'), ['prod_aguila', 'prod_ron']);
    await p.captura(sw('01-inventario-escritorio-con-boton-ocultar.png'));
    /* con stock en la bodega: se rechaza y no se escribe nada */
    await ocultar(p, 'prod_ron');
    await p.esperar("document.getElementById('toast').classList.contains('s')", 5000);
    assert.match(await toastTxt(p), /existencias en la bodega/); assert.equal(escriturasOculto(db).length, 0); assert.equal(fila(db, 'prod_ron').oculto, false);
    assert.ok((await nombres(p)).includes('Ron Medellin'));
    /* sin existencias: se oculta con UNA escritura condicionada, solo de la marca */
    p.supabase.length = 0; await ocultar(p, 'prod_aguila');
    await p.esperar("!document.querySelector('#invTableBody [data-accion=\"ocultar\"][onclick*=\"prod_aguila\"]')", 5000, 'oculto');
    assert.deepEqual(db.escrituras.map(e => e.metodo + ' ' + e.tabla + ' ' + JSON.stringify(e.cuerpo)), ['PATCH inv {"oculto":true}']);
    assert.deepEqual(db.escrituras[0].filtros, { id: 'prod_aguila', stock: '0', uds_sueltas: '0' }, 'PATCH condicionado a stock=0 y uds_sueltas=0');
    assert.deepEqual(p.supabase.filter(x => !x.startsWith('GET') && !x.startsWith('OPTIONS')), ['PATCH /rest/v1/inventario'], 'no se escribe en ninguna otra tabla (compras, ventas, cotizaciones, catalogo, bodegas...)');
    assert.ok(!(await nombres(p)).includes('Aguila 330')); assert.match(await chip(p), /Ocultos \(2\)/); assert.equal(await total(p), '4');
    /* vista Ocultos: solo los ocultos, con "Volver a mostrar" y sin acciones de stock */
    await verOcultos(p);
    iguales(await nombres(p), ['Aguila 330', 'Vino Tinto']);
    assert.deepEqual((await botones(p, 'mostrar')).sort(), ['prod_aguila', 'prod_vino']);
    assert.equal(await p.evaluar("document.querySelectorAll('#invTableBody .inv-act-btn').length"), 2, 'solo "Volver a mostrar" en esa vista');
    await p.captura(sw('02-vista-ocultos-escritorio.png'));
    /* volver a mostrar: reaparece y deja de estar en Ocultos */
    db.escrituras.length = 0; await p.clic('#invTableBody [data-accion="mostrar"][onclick*="prod_aguila"]');
    await p.esperar("document.querySelectorAll('#invTableBody tr').length===1", 5000);
    assert.deepEqual(db.escrituras.map(e => e.metodo + ' ' + JSON.stringify(e.cuerpo)), ['PATCH {"oculto":false}']); assert.equal(fila(db, 'prod_aguila').oculto, false);
    await p.clic('#invFbHidden'); await sleep(300);                                 /* sale de la vista Ocultos */
    assert.ok((await nombres(p)).includes('Aguila 330')); assert.match(await chip(p), /Ocultos \(1\)/);
    /* ocultar conserva el producto: ningun otro campo cambio y nada se borro */
    const sem = semilla(); sem.find(x => x.id === 'prod_vino').oculto = true;
    assert.deepEqual(db.inv, sem, 'la tabla quedo igual que al inicio (solo se toco la marca y se restauro)');
    assert.equal(db.escrituras.filter(e => e.metodo === 'DELETE').length, 0);
  } finally { await cerrar(s); }
});

test('PERSISTE entre recargas y dispositivos', opciones, async () => {
  const db = crearBase(); const s = await sesion(db); let s2 = null;
  try {
    const { p } = s; await irInventario(p); await ocultar(p, 'prod_aguila');
    await p.esperar("!document.querySelector('[data-accion=\"ocultar\"][onclick*=\"prod_aguila\"]')", 5000);
    await p.recargar(); await p.esperar("INVENTARIO.length>0", 30000); await irInventario(p);
    assert.ok(!(await nombres(p)).includes('Aguila 330'), 'tras recargar sigue oculto'); assert.match(await chip(p), /Ocultos \(2\)/);
    /* otro dispositivo (contexto limpio, misma base) */
    s2 = await sesion(db); await irInventario(s2.p);
    assert.ok(!(await nombres(s2.p)).includes('Aguila 330'), 'el otro dispositivo tambien lo ve oculto');
    await verOcultos(s2.p); await s2.p.clic('#invTableBody [data-accion="mostrar"][onclick*="prod_aguila"]');   /* lo recupera alli */
    await s2.p.esperar("document.querySelectorAll('#invTableBody tr').length===1", 5000);
    await p.recargar(); await p.esperar("INVENTARIO.length>0", 30000); await irInventario(p);
    assert.ok((await nombres(p)).includes('Aguila 330'), 'el primer dispositivo lo ve de nuevo tras recargar');
  } finally { await cerrar(s); if (s2) await cerrar(s2); }
});

test('RECIBIR EXISTENCIAS: un producto oculto vuelve a aparecer (entrada real, unidades sueltas, bodega) y no se vuelve a ocultar solo', opciones, async () => {
  const db = crearBase(); const s = await sesion(db);
  try {
    const { p } = s; await irInventario(p);
    /* a) entrada REAL de la aplicacion sobre el producto ya oculto (Vino): Entrada de mercancia -> guardar */
    assert.ok(!(await nombres(p)).includes('Vino Tinto'));
    await p.evaluar("openInvModal('prod_vino','entrada');true"); await sleep(500);
    await p.escribir('#invModalQty', '3'); await p.escribir('#invModalPrecio', '1500');
    await p.clic('#invModalOverlay .inv-btn-save');
    await p.esperar("(INVENTARIO.find(function(x){return x.id==='prod_vino';})||{}).stock===3", 8000, 'entrada registrada');
    await p.evaluar("closeInvModal();renderInvTable();true");
    await p.esperar("(" + NOMBRES_JS + ").indexOf('Vino Tinto')>=0", 8000, 'reaparece en la lista');
    await p.esperar("(INVENTARIO.find(function(x){return x.id==='prod_vino';})||{}).oculto===false", 8000, 'marca limpiada');
    assert.equal(fila(db, 'prod_vino').oculto, false, 'la marca se limpio en la base'); assert.equal(fila(db, 'prod_vino').stock, 3);
    /* si luego se agota, ya no vuelve a esconderse solo */
    await p.evaluar("var v=INVENTARIO.find(function(x){return x.id==='prod_vino';});v.stock=0;renderInvTable();renderInvStats();true");
    assert.ok((await nombres(p)).includes('Vino Tinto'), 'agotado, sigue visible (la marca ya no existe)');
    /* b) unidades sueltas recibidas por otro dispositivo */
    await ocultar(p, 'prod_aguila'); await p.esperar("!document.querySelector('[data-accion=\"ocultar\"][onclick*=\"prod_aguila\"]')", 5000);
    fila(db, 'prod_aguila').uds_sueltas = 2;
    await p.recargar(); await p.esperar("INVENTARIO.length>0", 30000); await irInventario(p);
    assert.ok((await nombres(p)).includes('Aguila 330'), 'con unidades sueltas vuelve a aparecer');
    assert.equal(fila(db, 'prod_aguila').oculto, false, 'y la marca se limpia');
    /* c) existencias que llegan a la BODEGA (traslado): al volver a Principal reaparece */
    fila(db, 'prod_aguila').uds_sueltas = 0; await p.recargar(); await p.esperar("INVENTARIO.length>0", 30000); await irInventario(p);
    await ocultar(p, 'prod_aguila'); await p.esperar("!document.querySelector('[data-accion=\"ocultar\"][onclick*=\"prod_aguila\"]')", 5000);
    db.bod.push({ id: 'b2', id_licencia: 'lacava', id_bodega: 'bod1', prod_id: 'prod_aguila', stock: 3, uds_sueltas: 0 });
    await p.evaluar("showInvTab('bodegas');true"); await sleep(300); await p.evaluar("showInvTab('principal');true");
    await p.esperar("(" + NOMBRES_JS + ").indexOf('Aguila 330')>=0", 8000, 'reaparece por la bodega');
    await sleep(500); assert.equal(fila(db, 'prod_aguila').oculto, false);
  } finally { await cerrar(s); }
});

test('RECHAZO cuando hay existencias: la lectura es real (no el array local) y la escritura es condicionada', opciones, async () => {
  const db = crearBase(); const s = await sesion(db);
  try {
    const { p } = s; await irInventario(p);
    const mensaje = async () => { await p.esperar("document.getElementById('toast').classList.contains('s')", 5000); return toastTxt(p); };
    /* stock que entro en otro dispositivo despues de cargar: la pantalla aun lo ve en cero */
    fila(db, 'prod_aguila').stock = 3;
    await ocultar(p, 'prod_aguila'); assert.match(await mensaje(), /existencias en el inventario principal/);
    assert.equal(escriturasOculto(db).length, 0, 'no se escribio nada'); assert.equal(fila(db, 'prod_aguila').oculto, false);
    assert.equal(await p.evaluar("(INVENTARIO.find(function(x){return x.id==='prod_aguila';})).stock"), 3, 'la pantalla se corrigio con el valor real');
    assert.ok(!(await botones(p, 'ocultar')).includes('prod_aguila'), 'y ya no ofrece Ocultar');
    /* unidades sueltas */
    assert.equal(await p.evaluar("ocultarProductoInv('prod_poker').then(function(){return document.getElementById('toast').textContent;})"), 'No se puede ocultar: el producto tiene existencias en el inventario principal.');
    assert.equal(fila(db, 'prod_poker').oculto, false);
    /* carrera: el stock cambia JUSTO entre la lectura y la escritura -> el PATCH condicionado no actualiza nada */
    fila(db, 'prod_aguila').stock = 0; await p.recargar(); await p.esperar("INVENTARIO.length>0", 30000); await irInventario(p);
    db.antesDePatch = d => { fila(d, 'prod_aguila').stock = 1; };
    await ocultar(p, 'prod_aguila'); assert.match(await mensaje(), /cambió justo ahora/);
    assert.equal(fila(db, 'prod_aguila').oculto, false); assert.ok((await nombres(p)).includes('Aguila 330'), 'sigue visible');
    /* un solo producto con stock en bodega -> rechazo (ya cubierto arriba) y sin poder leer: no se oculta */
    p.fallar = false; await p.evaluar("window.__f=window.fetch;window.fetch=function(u,o){if(String(u).indexOf('inventario_bodega?prod_id')>=0)return Promise.resolve(new Response('{}',{status:500}));return window.__f.apply(this,arguments);};true");
    fila(db, 'prod_aguila').stock = 0; await p.evaluar("INVENTARIO.find(function(x){return x.id==='prod_aguila';}).stock=0;renderInvTable();true"); await sleep(300);
    db.escrituras.length = 0; await ocultar(p, 'prod_aguila'); assert.match(await mensaje(), /No se pudo verificar las existencias/);
    assert.equal(escriturasOculto(db).length, 0, 'si no se puede verificar, no se oculta'); await p.evaluar("window.fetch=window.__f;true");
  } finally { await cerrar(s); }
});

test('FALLOS: guardado que falla, base sin la columna (SQL no aplicado) y lectura de bodega que falla no ocultan nada', opciones, async () => {
  const db = crearBase(); const s = await sesion(db);
  try {
    const { p } = s; await irInventario(p);
    const mensaje = async () => { await p.esperar("document.getElementById('toast').classList.contains('s')", 5000); return toastTxt(p); };
    db.fallar = true; await ocultar(p, 'prod_aguila'); assert.match(await mensaje(), /No se pudo ocultar/); db.fallar = false;
    assert.ok((await nombres(p)).includes('Aguila 330'), 'el guardado fallo: sigue visible'); assert.equal(fila(db, 'prod_aguila').oculto, false);
    await sleep(2700);
    db.sinColumna = true; await ocultar(p, 'prod_aguila'); assert.match(await mensaje(), /Falta activar esta función en la base de datos/);
    assert.ok((await nombres(p)).includes('Aguila 330'));
    /* sin la columna, al cargar nada aparece oculto (ni siquiera Vino) y la aplicacion funciona igual */
    await p.recargar(); await p.esperar("INVENTARIO.length>0", 30000); await irInventario(p);
    assert.ok((await nombres(p)).includes('Vino Tinto'), 'sin la columna no hay productos ocultos'); assert.match(await chip(p), /Ocultos \(0\)/);
  } finally { await cerrar(s); }
});

test('el alcance es solo la presentacion de Inventario: POS, Compras, Cotizaciones, Entrada y bodegas siguen viendo el producto oculto', opciones, async () => {
  const db = crearBase(); const s = await sesion(db);
  try {
    const { p } = s; await irInventario(p); await ocultar(p, 'prod_aguila'); await p.esperar("!document.querySelector('[data-accion=\"ocultar\"][onclick*=\"prod_aguila\"]')", 5000);
    assert.equal(await p.evaluar("INVENTARIO.some(function(x){return x.id==='prod_aguila';})"), true, 'INVENTARIO (fuente de POS, Compras, Cotizaciones y Catalogo) sigue completo');
    assert.equal(await p.evaluar("(renderCotProdGrid(),document.getElementById('cotProdGrid').innerText.indexOf('Aguila')>=0)"), true, 'Cotizaciones');
    assert.equal(await p.evaluar("(buildInvSelect(),Array.from(document.querySelectorAll('#invModalProd option')).some(function(o){return o.value==='prod_aguila';}))"), true, 'selector de Entrada de mercancia (permite recibir y reaparecer)');
    assert.equal(await p.evaluar("typeof CAT_HIDDEN!=='undefined'&&CAT_HIDDEN.indexOf('prod_aguila')<0"), true, 'el catalogo virtual usa su propia marca: no cambia');
    /* revision de codigo: las funciones de ocultar solo se usan dentro del modulo Inventario */
    const html = fs.readFileSync(path.join(RAIZ, 'dashboard_lacava.html'), 'utf8');
    const a = html.indexOf('/* ==================== MODULO INVENTARIO'), b = html.indexOf('/* ==================== IMAGENES DE PRODUCTOS');
    assert.ok(a > 0 && b > a);
    for (const f of ['invVisibles(', 'invOcultos(', 'invEstaOculto(', 'invSinExistencias(', 'ocultarProductoInv(', 'mostrarProductoInv(']) {
      let i = -1; while ((i = html.indexOf(f, i + 1)) >= 0) assert.ok(i > a && i < b || html.slice(Math.max(0, i - 60), i + 80).indexOf('onclick') >= 0, f + ' fuera del modulo Inventario en la posicion ' + i);
    }
  } finally { await cerrar(s); }
});

/* ======================= movil ======================= */

test('MOVIL (390x844): se ve la lista, se puede ocultar, abrir Ocultos y volver a mostrar sin desplazamiento horizontal de la pagina', opciones, async () => {
  const db = crearBase(); const s = await sesion(db, { movil: true });
  try {
    const { p } = s; await irInventario(p);
    const sinDesborde = async (que) => assert.equal(await p.evaluar("document.documentElement.scrollWidth<=window.innerWidth+1"), true, 'sin desplazamiento horizontal: ' + que);
    await sinDesborde('lista');
    await p.evaluar("document.getElementById('invFbHidden').scrollIntoView({block:'center'});true"); await sleep(300);
    await p.captura(sw('m01-inventario-movil-filtros.png'));
    await p.evaluar("document.querySelector('#invTableBody [data-accion=\"ocultar\"][onclick*=\"prod_aguila\"]').scrollIntoView({block:'center',inline:'center'});true"); await sleep(300);
    await p.captura(sw('m02-inventario-movil-boton-ocultar.png'));
    await ocultar(p, 'prod_aguila'); await p.esperar("!document.querySelector('[data-accion=\"ocultar\"][onclick*=\"prod_aguila\"]')", 5000);
    assert.equal(fila(db, 'prod_aguila').oculto, true);
    await p.evaluar("document.getElementById('invFbHidden').scrollIntoView({block:'center'});true"); await sleep(200);
    await verOcultos(p); iguales(await nombres(p), ['Aguila 330', 'Vino Tinto']); await sinDesborde('ocultos');
    await p.captura(sw('m03-vista-ocultos-movil.png'));
    await p.clic('#invTableBody [data-accion="mostrar"][onclick*="prod_aguila"]');
    await p.esperar("document.querySelectorAll('#invTableBody tr').length===1", 5000); assert.equal(fila(db, 'prod_aguila').oculto, false);
    assert.equal(await p.evaluar("(function(){var r=document.getElementById('invFbHidden').getBoundingClientRect();return r.left>=0&&r.right<=window.innerWidth;})()"), true, 'el filtro Ocultos cabe en pantalla');
  } finally { await cerrar(s); }
});

/* ======================= reaparicion de productos ocultos: limpieza de la marca ======================= */
const intentosLimpieza = db => db.escrituras.filter(e => e.tabla === 'inv' && e.cuerpo && e.cuerpo.oculto === false).length;
const marca = (p, id) => p.evaluar("(INVENTARIO.find(function(x){return x.id==='" + id + "';})||{})._limpiando");
const entradaReal = async (p, id, qty) => {   /* la misma pantalla de Entrada de la aplicacion (guardarInvAjuste -> ajustarStockAtomicoSB) */
  await p.evaluar("openInvModal('" + id + "','entrada');true"); await sleep(500);
  await p.escribir('#invModalQty', String(qty)); await p.escribir('#invModalPrecio', '1500');
  await p.clic('#invModalOverlay .inv-btn-save');
  await p.esperar("(INVENTARIO.find(function(x){return x.id==='" + id + "';})||{}).stock===" + qty, 8000, 'entrada registrada');
  await p.evaluar('closeInvModal();true');
};
const agotar = (p, id) => p.evaluar("ajustarStockAtomicoSB('" + id + "',function(){return {stock:0,uds_sueltas:0};}).then(function(r){if(r.ok)INVENTARIO.find(function(x){return x.id==='" + id + "';}).stock=0;return r.ok;})");   /* lo que hace una venta al agotarlo: CAS en la base y el array local queda al dia */

test('LIMPIEZA: un fallo libera _limpiando, no hay peticiones simultaneas y se reintenta despues', opciones, async () => {
  const db = crearBase(); fila(db, 'prod_vino').stock = 3; db.fallarLimpieza = true;      /* oculto, pero con existencias */
  const s = await sesion(db);
  try {
    const { p } = s; await irInventario(p);
    assert.ok((await nombres(p)).includes('Vino Tinto'), 'con existencias se muestra (visibilidad efectiva) aunque la marca siga guardada');
    await p.esperar("(INVENTARIO.find(function(x){return x.id==='prod_vino';}))._limpiando===false", 5000, 'liberado tras el fallo');
    assert.equal(intentosLimpieza(db), 1, 'un intento'); assert.equal(fila(db, 'prod_vino').oculto, true, 'la marca almacenada sigue (la limpieza fallo)');
    assert.equal(await p.evaluar("INVENTARIO.find(function(x){return x.id==='prod_vino';}).oculto"), true);
    /* renders seguidos (buscar, filtros) NO disparan una avalancha de reintentos: se espera el intervalo */
    for (let i = 0; i < 5; i++) await p.evaluar("renderInvTable();true");
    await sleep(300);
    assert.equal(intentosLimpieza(db), 1, 'sin reintentos antes del intervalo');
    /* tras el intervalo se reintenta (y no hay dos peticiones a la vez aunque haya muchos renders mientras la primera sigue en vuelo) */
    db.fallarLimpieza = false;
    await p.evaluar("var f=window.fetch;window.__cnt=0;window.fetch=function(u,o){if(o&&o.method==='PATCH'&&String(o.body).indexOf('\"oculto\":false')>=0){window.__cnt++;return new Promise(function(r){setTimeout(r,700);}).then(function(){return f.call(window,u,o);});}return f.apply(this,arguments);};var n=Date.now;Date.now=function(){return n.call(Date)+6000;};true");
    for (let i = 0; i < 6; i++) await p.evaluar("renderInvTable();true");
    assert.equal(await p.evaluar('window.__cnt'), 1, 'una sola peticion en vuelo a la vez');
    assert.equal(await marca(p, 'prod_vino'), true, 'ocupado mientras la peticion esta en vuelo');
    await p.esperar("(INVENTARIO.find(function(x){return x.id==='prod_vino';})).oculto===false", 8000, 'reintento correcto');
    assert.equal(fila(db, 'prod_vino').oculto, false); assert.equal(await marca(p, 'prod_vino'), false, 'y se libera tambien tras el exito');
    assert.equal(intentosLimpieza(db), 2);
  } finally { await cerrar(s); }
});

test('RECIBIR y AGOTAR sin abrir Inventario: la marca se limpia al recibir; si esa limpieza falla, la marca se conserva y solo se ve mientras hay stock', opciones, async () => {
  /* a0) recepcion SIN ninguna pantalla de Inventario ni render (como una compra recibida desde Compras): solo el CAS de stock, que es el unico camino de entrada */
  let db = crearBase(); let s = await sesion(db);
  try {
    const { p } = s;
    assert.equal(await p.evaluar("ajustarStockAtomicoSB('prod_vino',function(st,su){return {stock:st+3,uds_sueltas:su};}).then(function(r){return r.ok;})"), true);
    await p.esperar("(INVENTARIO.find(function(x){return x.id==='prod_vino';})).oculto===false", 8000, 'marca limpiada por la propia recepcion');
    assert.equal(fila(db, 'prod_vino').oculto, false, 'sin abrir Inventario ni renderizar nada');
    assert.equal(await agotar(p, 'prod_vino'), true);
    await irInventario(p); assert.ok((await nombres(p)).includes('Vino Tinto'), 'y al agotarse sigue visible');
  } finally { await cerrar(s); }
  /* a) camino normal: entrada real -> se agota -> recien despues se abre Inventario */
  db = crearBase(); s = await sesion(db);
  try {
    const { p } = s;      /* NO se abre Inventario */
    assert.equal(fila(db, 'prod_vino').oculto, true);
    await entradaReal(p, 'prod_vino', 3);
    await p.esperar("(INVENTARIO.find(function(x){return x.id==='prod_vino';})).oculto===false", 8000, 'marca limpiada al recibir');
    assert.equal(fila(db, 'prod_vino').oculto, false, 'la marca se limpio en la base al recibir, sin abrir Inventario');
    assert.equal(await agotar(p, 'prod_vino'), true); assert.equal(fila(db, 'prod_vino').stock, 0);
    await irInventario(p);
    assert.ok((await nombres(p)).includes('Vino Tinto'), 'agotado antes de abrir Inventario: ya no vuelve a esconderse');
    assert.match(await chip(p), /Ocultos \(0\)/);
  } finally { await cerrar(s); }
  /* b) LIMITACION: la limpieza falla al recibir (red) y se agota antes de abrir Inventario -> la marca sigue y vuelve a estar oculto */
  db = crearBase(); db.fallarLimpieza = true; s = await sesion(db);
  try {
    const { p } = s;
    await entradaReal(p, 'prod_vino', 3); await sleep(500);
    assert.equal(fila(db, 'prod_vino').oculto, true, 'la limpieza fallo: la marca almacenada se conserva');
    assert.equal(await agotar(p, 'prod_vino'), true);
    await irInventario(p);
    assert.ok(!(await nombres(p)).includes('Vino Tinto'), 'visibilidad efectiva: oculto de nuevo (tuvo stock y se agoto sin que la limpieza llegara a guardarse)');
    assert.match(await chip(p), /Ocultos \(1\)/);
    /* con la red de vuelta, la siguiente recepcion limpia la marca */
    db.fallarLimpieza = false; await p.evaluar("var n=Date.now;Date.now=function(){return n.call(Date)+6000;};true");
    await entradaReal(p, 'prod_vino', 2);
    await p.esperar("(INVENTARIO.find(function(x){return x.id==='prod_vino';})).oculto===false", 8000, 'limpiada al reintentar');
    assert.equal(fila(db, 'prod_vino').oculto, false);
  } finally { await cerrar(s); }
});

test('CARRERA: una entrada en la bodega entre la lectura y el PATCH de ocultar no deja el producto oculto', opciones, async () => {
  const db = crearBase(); const s = await sesion(db);
  try {
    const { p } = s; await irInventario(p);
    const mensaje = async () => { await p.esperar("document.getElementById('toast').classList.contains('s')", 5000); return toastTxt(p); };
    /* la bodega recibe 2 unidades justo despues de leerla y antes de escribir la marca (el PATCH condicionado solo mira el inventario principal) */
    db.antesDePatch = d => { d.bod.push({ id: 'b9', id_licencia: 'lacava', id_bodega: 'bod1', prod_id: 'prod_aguila', stock: 2, uds_sueltas: 0 }); };
    await ocultar(p, 'prod_aguila'); assert.match(await mensaje(), /recibió existencias en la bodega justo ahora: sigue visible/);
    assert.ok((await nombres(p)).includes('Aguila 330'), 'visibilidad efectiva: sigue visible aunque la marca se llegara a guardar');
    await p.esperar("(INVENTARIO.find(function(x){return x.id==='prod_aguila';})).oculto===false", 8000, 'marca almacenada limpiada');
    assert.equal(fila(db, 'prod_aguila').oculto, false, 'la marca almacenada tambien se limpia');
    assert.match(await chip(p), /Ocultos \(1\)/, 'solo el que ya estaba oculto');
    /* LIMITACION: si la entrada llega DESPUES de la comprobacion posterior, la marca queda guardada y la pantalla sigue ocultandolo hasta el siguiente refresco */
    db.bod.length = 1; await p.recargar(); await p.esperar("INVENTARIO.length>0", 30000); await irInventario(p);
    await ocultar(p, 'prod_aguila'); await p.esperar("!document.querySelector('[data-accion=\"ocultar\"][onclick*=\"prod_aguila\"]')", 5000);
    db.bod.push({ id: 'b10', id_licencia: 'lacava', id_bodega: 'bod1', prod_id: 'prod_aguila', stock: 1, uds_sueltas: 0 });
    assert.equal(fila(db, 'prod_aguila').oculto, true); assert.ok(!(await nombres(p)).includes('Aguila 330'), 'hasta refrescar, la pantalla aun lo oculta (mapa de bodega previo)');
    await p.evaluar("showInvTab('bodegas');true"); await sleep(300); await p.evaluar("showInvTab('principal');true");
    await p.esperar("(" + NOMBRES_JS + ").indexOf('Aguila 330')>=0", 8000, 'reaparece al refrescar');
    await sleep(500); assert.equal(fila(db, 'prod_aguila').oculto, false, 'y la marca se limpia');
  } finally { await cerrar(s); }
});
