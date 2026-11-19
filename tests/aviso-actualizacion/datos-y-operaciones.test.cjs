'use strict';
/* Pruebas especificas de dos garantias del aviso de actualizacion, en un navegador real con los archivos reales de deploy/:
   1) DATOS SIN GUARDAR: selectores, fechas, casillas y opciones de formularios editables cuentan; los filtros no; guardar y cancelar limpian el estado;
      "Volver" conserva los valores.
   2) OPERACION COMPLETA: "Actualizar" permanece bloqueado durante toda la operacion, tambien en las pausas entre escrituras (mas de 1,5 s). */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { lanzar, sleep } = require('./cdp.cjs');
const { crear } = require('./servidor-versiones.cjs');
const { preparar } = require('./versiones.cjs');

const EVIDENCIA = process.env.LACAVA_EVIDENCIA || path.join(os.homedir(), 'LaCava-evidencia-local', 'aviso-actualizacion');
let nav = null, srv = null, base = null, V = null;
const SKIP = (fs.existsSync('C:/Program Files/Google/Chrome/Application/chrome.exe') || fs.existsSync('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe') || !!process.env.LACAVA_NAVEGADOR) ? false : 'no hay Chrome ni Edge';
before(async () => { if (SKIP) return; V = preparar(); srv = crear(V.dirs, 'v1'); base = await srv.iniciar(); nav = await lanzar(); });
after(async () => { if (nav) await nav.cerrar(); if (srv) await srv.cerrar(); if (V) V.limpiar(); });

const js = {
  banner: "(function(){var e=document.getElementById('lcUpd');return !!e&&getComputedStyle(e).display!=='none';})()",
  ok: "document.querySelector('#lcUpd .lcu-ok')"
};
const sw = n => path.join(EVIDENCIA, n);
const opciones = { timeout: 120000, skip: SKIP };
const estado = p => p.evaluar('__lcUpd.estado()');
const sinGuardar = async p => (await estado(p)).sinGuardar;
const textoBanner = p => p.evaluar("document.getElementById('lcUpd').innerText");
const valor = (p, id) => p.evaluar("(function(){var e=document.getElementById(" + JSON.stringify(id) + ");return e.type==='checkbox'||e.type==='radio'?e.checked:e.value;})()");

async function sesion() {
  srv.cambiar('v1');
  const ctx = await nav.contexto(); const p = await nav.pagina(ctx);
  await p.ir(base + '/');
  await p.esperar("!!navigator.serviceWorker.controller&&getComputedStyle(document.getElementById('app')).display==='flex'", 45000, 'aplicacion con service worker');
  const t0 = Date.now(); while (!p.consola.some(l => l.indexOf('[SW] Registrado') >= 0) && Date.now() - t0 < 10000) await sleep(100);
  return { ctx, p };
}
const cerrar = async s => { await s.p.cerrar(); await nav.cerrarContexto(s.ctx); };
async function hayNueva(p) { srv.cambiar('v2'); await p.evaluar('__lcUpd.revisar()'); await p.esperar(js.banner, 20000, 'aviso visible'); }
async function irAGastos(p) { await p.evaluar("goView('gastos');true"); await p.esperar("document.getElementById('gastoCategoria').getClientRects().length>0", 8000, 'formulario de gastos'); }
async function cambiarSelector(p, sel) { await p.enfocar(sel); await p.tecla('ArrowDown'); }
const libre = p => p.esperar("__lcUpd.estado().ocupado===false&&document.querySelector('#lcUpd .lcu-ok').disabled===false", 12000, 'operacion terminada, margen cumplido y boton liberado');

/* ======================= 1) DATOS SIN GUARDAR ======================= */

test('modificar SOLO un selector, una fecha o una casilla cuenta como dato sin guardar; Volver conserva los valores', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p); await irAGastos(p);
    assert.deepEqual(await sinGuardar(p), [], 'nada tocado: nada sin guardar');
    /* selector real (categoria del gasto) */
    const cat0 = await valor(p, 'gastoCategoria');
    await cambiarSelector(p, '#gastoCategoria');
    const cat1 = await valor(p, 'gastoCategoria'); assert.notEqual(cat1, cat0, 'el selector cambio');
    let l = await sinGuardar(p); assert.equal(l.length, 1); assert.match(l[0], /categor/i);
    /* volver al valor inicial = ya no hay cambio */
    await p.tecla('ArrowUp'); assert.equal(await valor(p, 'gastoCategoria'), cat0); assert.deepEqual(await sinGuardar(p), []);
    await p.tecla('ArrowDown');
    /* fecha real (fecha del gasto) */
    const fecha0 = await valor(p, 'gastoFecha');
    await p.enfocar('#gastoFecha'); await p.digitos('01022027');
    assert.notEqual(await valor(p, 'gastoFecha'), fecha0, 'la fecha cambio');
    l = await sinGuardar(p); assert.equal(l.length, 2); assert.ok(l.some(x => /fecha/i.test(x)), JSON.stringify(l));
    /* casilla y opcion de un formulario editable (modal de proveedor con una casilla y dos opciones) */
    await p.evaluar("abrirModalProveedor();var c=document.querySelector('#modalProveedor input');var d=document.createElement('div');d.id='extraForm';d.innerHTML='<label><input type=\"checkbox\" id=\"chkProvFrecuente\"> Proveedor frecuente</label><label><input type=\"radio\" name=\"tipoProv\" id=\"radA\" checked> Contado</label><label><input type=\"radio\" name=\"tipoProv\" id=\"radB\"> Credito</label>';c.parentElement.appendChild(d);true"); await sleep(700);
    await p.clic('#chkProvFrecuente');
    assert.ok((await sinGuardar(p)).includes('Proveedor frecuente'), 'la casilla sola cuenta');
    await p.clic('#chkProvFrecuente'); assert.ok(!(await sinGuardar(p)).includes('Proveedor frecuente'), 'volver a dejarla como estaba: limpio');
    await p.clic('#radB'); assert.ok((await sinGuardar(p)).some(x => /Credito/.test(x)), 'la opcion elegida cuenta');
    await p.clic('#radA'); assert.ok(!(await sinGuardar(p)).some(x => /Credito|Contado/.test(x)), 'volver a la opcion inicial: limpio');
    await p.clic('#chkProvFrecuente'); await p.clic('#radB');
    /* Actualizar advierte con todo, y Volver conserva TODOS los valores */
    const antes = { cat: await valor(p, 'gastoCategoria'), fecha: await valor(p, 'gastoFecha'), chk: await valor(p, 'chkProvFrecuente'), rad: await valor(p, 'radB') };
    const n0 = p.navegaciones;
    await p.clic('#lcUpd .lcu-ok');
    await p.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar y descartar'", 5000, 'confirmacion');
    const t = await textoBanner(p); assert.match(t, /Sin guardar:/); assert.match(t, /categor/i); assert.match(t, /fecha/i); assert.match(t, /Proveedor frecuente/); assert.match(t, /Credito/);
    await new Promise(r => setTimeout(r, 700)); await p.captura(sw('08-selector-fecha-casilla-sin-guardar.png'));
    await p.clic('#lcUpd .lcu-no');   /* Volver */
    await p.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar'", 5000);
    assert.deepEqual({ cat: await valor(p, 'gastoCategoria'), fecha: await valor(p, 'gastoFecha'), chk: await valor(p, 'chkProvFrecuente'), rad: await valor(p, 'radB') }, antes, 'Volver conserva los valores');
    assert.equal(p.navegaciones, n0, 'no se recargo');
  } finally { await cerrar(s); }
});

test('los FILTROS (selectores, fechas y busquedas de listados y reportes) no cuentan como datos sin guardar', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p);
    await p.evaluar("goView('gastos');true"); await p.esperar("document.getElementById('gastosFiltrocat').getClientRects().length>0", 8000);
    await cambiarSelector(p, '#gastosFiltrocat');
    await p.evaluar("for(var e=document.getElementById('gastosDesde');e&&e!==document.body;e=e.parentElement){if(getComputedStyle(e).display==='none')e.style.display='block';}true");   /* el rango de fechas del filtro puede estar plegado */
    await p.enfocar('#gastosDesde'); await p.digitos('03042026');
    assert.notEqual(await valor(p, 'gastosDesde'), '', 'la fecha del filtro cambio de verdad');
    assert.deepEqual(await sinGuardar(p), [], 'filtro de gastos');
    for (const [vista, ids] of [['compras', ['comprasFiltroEstado']], ['cotizaciones', ['cotFiltroEstado']], ['cartera', ['carteraFiltro']]]) {
      await p.evaluar("goView(" + JSON.stringify(vista) + ");true");
      for (const id of ids) { await p.esperar("document.getElementById(" + JSON.stringify(id) + ")&&document.getElementById(" + JSON.stringify(id) + ").getClientRects().length>0", 8000, id); await cambiarSelector(p, '#' + id); }
      assert.deepEqual(await sinGuardar(p), [], 'filtro de ' + vista);
    }
    /* y los campos de DATOS de esas mismas pantallas no se confunden con filtros */
    await p.evaluar("goView('gastos');true"); await p.esperar("document.getElementById('gastoCategoria').getClientRects().length>0", 8000);
    await cambiarSelector(p, '#gastoCategoria'); assert.equal((await sinGuardar(p)).length, 1);
  } finally { await cerrar(s); }
});

test('GUARDAR no marca nada como guardado por si solo: si el guardado FALLA se conserva todo; si sale bien solo deja de contar lo que la aplicacion limpia o cierra', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p); await irAGastos(p);
    await cambiarSelector(p, '#gastoCategoria'); await p.enfocar('#gastoFecha'); await p.digitos('01022027');
    await p.escribir('#gastoDescripcion', 'Arriendo de prueba'); await p.escribir('#gastoValor', '150000');
    assert.equal((await sinGuardar(p)).length, 4, JSON.stringify(await sinGuardar(p)));
    /* 1) guardado que FALLA (la base responde 500): el formulario queda como estaba y todo sigue contando */
    p.fallar = true;
    await p.clic('#btnGuardarGasto');
    await p.esperar("__lcUpd.estado().operaciones===0&&__lcUpd.estado().ocupado===false", 8000, 'guardado fallido terminado');
    assert.ok(p.supabase.indexOf('POST /rest/v1/gastos') >= 0, 'se intento guardar');
    assert.equal(await valor(p, 'gastoDescripcion'), 'Arriendo de prueba', 'la aplicacion conserva lo escrito');
    assert.equal((await sinGuardar(p)).length, 4, 'tras el fallo nada se da por guardado: ' + JSON.stringify(await sinGuardar(p)));
    await p.clic('#lcUpd .lcu-ok');                                   /* y Actualizar sigue advirtiendo */
    await p.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar y descartar'", 5000, 'advertencia tras guardado fallido');
    await p.clic('#lcUpd .lcu-no');
    /* 2) guardado que sale bien: la aplicacion limpia descripcion y valor; fecha y categoria (que deja puestas) siguen contando: mas vale una advertencia de mas */
    p.fallar = false;
    await p.clic('#btnGuardarGasto');
    await p.esperar("__lcUpd.estado().operaciones===0", 8000, 'guardado terminado');
    assert.equal(await valor(p, 'gastoDescripcion'), '', 'la aplicacion limpio la descripcion');
    const l = await sinGuardar(p);
    assert.equal(l.length, 2, JSON.stringify(l)); assert.ok(l.some(x => /fecha/i.test(x)) && l.some(x => /categor/i.test(x)), JSON.stringify(l));
  } finally { await cerrar(s); }
});

test('CANCELAR limpia el estado: cerrar un formulario con selector y texto (y reabrirlo) no deja nada sin guardar', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p);
    await p.evaluar('openNuevoProd();true'); await p.esperar("document.getElementById('npCategoria').getClientRects().length>0", 8000, 'modal de producto'); await sleep(700);
    await cambiarSelector(p, '#npCategoria'); await p.escribir('#npNombre', 'Producto de prueba');
    const l = await sinGuardar(p); assert.ok(l.length >= 1, JSON.stringify(l)); assert.ok(l.some(x => /categor/i.test(x)), JSON.stringify(l));
    await p.clic('#modalNuevoProd button[onclick="closeNuevoProd()"]');     /* Cancelar */
    await p.esperar("__lcUpd.estado().sinGuardar.length===0", 3000, 'limpio tras cancelar');
    await p.evaluar('openNuevoProd();true'); await sleep(1300);             /* reabrir: la aplicacion lo deja como nuevo */
    assert.deepEqual(await sinGuardar(p), [], 'reabierto y sin tocar: nada sin guardar');
    await p.evaluar('closeNuevoProd();true');
    /* y con el modal de proveedor (texto) */
    await p.evaluar('abrirModalProveedor();true'); await sleep(700); await p.escribir('#modalProvNombre', 'Cancelado');
    assert.equal((await sinGuardar(p)).length, 1);
    await p.clic('#modalProveedor button[onclick="cerrarModalProveedor()"]');
    await p.esperar("__lcUpd.estado().sinGuardar.length===0", 3000, 'limpio tras cancelar proveedor');
  } finally { await cerrar(s); }
});

test('ventas y cotizaciones ABIERTAS PARA EDICION: cambios en productos, cantidades, precios y descuentos cuentan; abrir sin editar, o volver a lo inicial, no', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p);
    const hay = async (re) => (await sinGuardar(p)).some(x => re.test(x));
    /* datos de prueba: una venta con dos lineas (la aplicacion las lee de detalle_ventas) y una cotizacion con una linea */
    p.datos['detalle_ventas'] = [
      { id: 'd1', venta_id: 'venta-1', prod_id: 'p1', producto_nombre: 'Aguardiente', cantidad: 2, precio_unitario: 30000, precio_total: 60000 },
      { id: 'd2', venta_id: 'venta-1', prod_id: 'p2', producto_nombre: 'Cerveza', cantidad: 6, precio_unitario: 5000, precio_total: 30000 }];
    await p.evaluar("INVENTARIO.push({id:'p9',nombre:'Ron',precio_venta:50000,uds_empaque:1,categoria:'Licores'});" +
      "VENTAS_MES.push({id:'venta-1',numero_venta:7,domicilio:0,descuento:0});" +
      "true");
    /* ---------- VENTA abierta para edicion ---------- */
    await p.evaluar("abrirEditarVenta('venta-1');true");
    await p.esperar("document.querySelectorAll('#editVentaItems tbody tr').length===2", 8000, 'venta con sus dos lineas');
    await sleep(1300);                                                                      /* pasa el vigilante periodico */
    assert.deepEqual(await sinGuardar(p), [], 'abrir la venta sin editar no genera aviso');
    await p.clic('#editVentaItems button[onclick="editVentaChgQty(0,1)"]');                 /* cantidad +1 */
    assert.ok(await hay(/venta en edición con cambios/), 'cantidad: ' + JSON.stringify(await sinGuardar(p)));
    await p.clic('#editVentaItems button[onclick="editVentaChgQty(0,-1)"]');               /* y de vuelta a la inicial */
    assert.deepEqual(await sinGuardar(p), [], 'volver a la cantidad inicial: sin aviso');
    await p.evaluar("editVentaItemsArr[1].precio_unitario=5500;true");                       /* precio (la ventana no tiene campo de precio: se cambia el dato) */
    assert.ok(await hay(/venta en edición/), 'precio'); await p.evaluar("editVentaItemsArr[1].precio_unitario=5000;true");
    assert.deepEqual(await sinGuardar(p), []);
    await p.evaluar("document.getElementById('editVentaProdSel').value='p9';editVentaAgregarItem();true");   /* producto agregado... */
    assert.ok(await hay(/venta en edición/), 'producto agregado');
    await p.evaluar("editVentaElimItem(2);true");                                            /* ...y quitado: equivale al estado inicial */
    assert.deepEqual(await sinGuardar(p), [], 'agregar y quitar un producto nuevo = sin cambios');
    await p.clic('#editVentaItems button[onclick="editVentaElimItem(1)"]');                 /* quitar una linea original */
    assert.ok(await hay(/venta en edición/), 'producto quitado');
    await p.captura(sw('10-venta-en-edicion-con-cambios.png'));
    await p.clic('#lcUpd .lcu-ok'); await p.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar y descartar'", 5000, 'advertencia');
    assert.match(await textoBanner(p), /venta en edición con cambios/); await p.clic('#lcUpd .lcu-no');
    await p.evaluar('closeEditarVenta();true');                                              /* cancelar */
    await p.esperar("__lcUpd.estado().sinGuardar.length===0", 3000, 'limpio al cerrar');
    await p.evaluar("abrirEditarVenta('venta-1');true"); await p.esperar("document.querySelectorAll('#editVentaItems tbody tr').length===2", 8000);
    await sleep(1300); assert.deepEqual(await sinGuardar(p), [], 'reabrir: referencia nueva, sin aviso');
    await p.evaluar('closeEditarVenta();true');
    /* ---------- COTIZACION abierta para edicion ---------- */
    await p.evaluar("goView('cotizaciones');true"); await sleep(500);   /* la lista se recarga al entrar: se agrega despues */
    await p.evaluar("COTIZACIONES.push({id:'cot-1',_sbId:'sb-1',numero:3,cliente:'Cliente X',wa:'',estado:'pendiente',fecha_vencimiento:null," +
      "items:[{prod_id:'p1',nombre:'Aguardiente',cantidad:2,precio_unitario:30000,precio_total:60000,tipo:'und',descItem:0}]});true");
    
    await p.evaluar("editarCotizacion('cot-1');true"); await p.esperar("document.querySelectorAll('#cotItemsList button[onclick^=\"cotChgQty\"]').length===2", 8000, 'cotizacion con su linea');
    await sleep(1300);
    assert.deepEqual(await sinGuardar(p), [], 'abrir la cotizacion sin editar no genera aviso');
    await p.clic('#cotItemsList button[onclick="cotChgQty(0,1)"]');
    assert.ok(await hay(/cotización en edición con cambios/), 'cantidad: ' + JSON.stringify(await sinGuardar(p)));
    await p.clic('#cotItemsList button[onclick="cotChgQty(0,-1)"]'); assert.deepEqual(await sinGuardar(p), [], 'cantidad de vuelta: sin aviso');
    await p.evaluar("cotItems[0].precio_unitario=31000;cotItems[0].precio_total=62000;true");     /* precio */
    assert.ok(await hay(/cotización en edición/), 'precio'); await p.evaluar("cotItems[0].precio_unitario=30000;cotItems[0].precio_total=60000;true");
    assert.deepEqual(await sinGuardar(p), []);
    await p.clic('#cotItemsList button[onclick="cotToggleDesc(0)"]');                         /* descuento real de la linea: 10 % */
    await p.escribir('#cotDescInp_0', '10'); await p.clic('#cotItemsList button[onclick="cotConfirmarDesc(0)"]');
    assert.equal(await p.evaluar('cotItems[0].descItem'), 3000, 'la aplicacion aplico el descuento');
    assert.ok(await hay(/cotización en edición/), 'descuento: ' + JSON.stringify(await sinGuardar(p)));
    await p.captura(sw('11-cotizacion-en-edicion-con-cambios.png'));
    /* guardar que FALLA: la ventana sigue abierta y el cambio sigue contando; guardar bien la cierra */
    p.fallar = true; await p.clic('#modalCotizacion button[onclick="guardarCotizacion()"]');
    await p.esperar("__lcUpd.estado().operaciones===0", 8000, 'guardado fallido terminado');
    assert.equal(await p.evaluar("document.getElementById('modalCotizacion').style.display"), 'flex', 'la ventana sigue abierta');
    assert.ok(await hay(/cotización en edición/), 'tras fallar el guardado sigue sin guardar');
    p.fallar = false; await p.clic('#modalCotizacion button[onclick="guardarCotizacion()"]');
    await p.esperar("document.getElementById('modalCotizacion').style.display==='none'", 8000, 'guardada y cerrada');
    await p.esperar("__lcUpd.estado().sinGuardar.length===0", 3000, 'limpio tras guardar con exito');
  } finally { await cerrar(s); }
});

/* ======================= 2) OPERACION COMPLETA ======================= */

const OPERACION_LARGA = "window.operacionLarga=async function(){" +
  "await fetch(SB+'/rest/v1/gastos',{method:'POST',headers:H,body:'{}'});" +                   /* escritura 1 */
  "await new Promise(function(r){setTimeout(r,3500);});" +                                      /* pausa SIN ninguna peticion en vuelo (> 1,5 s) */
  "await fetch(SB+'/rest/v1/gastos?id=eq.1',{method:'PATCH',headers:H,body:'{}'});" +          /* escritura 2 */
  "return 'fin';};true";
const peticiones = (p, m) => p.supabase.filter(x => x.startsWith(m + ' /rest/v1/gastos')).length;

test('al cargar, se siguen de principio a fin las funciones de guardado reales de la aplicacion (incluidas las que llaman a otras)', opciones, async () => {
  const s = await sesion();
  try {
    const nombres = await s.p.evaluar('__lcUpd.envueltas()');
    for (const n of ['doVenta', 'guardarGasto', 'guardarProveedor', 'guardarCompra', 'recibirCompra', 'guardarEdicionCompra', 'guardarEdicionVenta', 'confirmarAbonoModal',
      'registrarAbonoCarteraSB', 'confirmarConversionCot', 'guardarCotizacion', 'confirmarAperturaCaja', 'confirmarCierreCaja', 'confirmarTraslado', 'eliminarVenta'])
      assert.ok(nombres.includes(n), 'falta ' + n);
    assert.ok(nombres.length > 50 && nombres.length < 150, 'cantidad razonable: ' + nombres.length);
  } finally { await cerrar(s); }
});

test('una operacion con PAUSA de mas de 1,5 s entre escrituras mantiene Actualizar bloqueado y no se puede actualizar durante la pausa', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p); await p.evaluar(OPERACION_LARGA); await p.evaluar('__lcUpd.envolver()');
    await p.evaluar('window.__op=operacionLarga();true'); const n0 = p.navegaciones;
    await p.esperar("__lcUpd.estado().ocupado===true", 3000);
    await new Promise(r => setTimeout(r, 400));
    assert.equal(peticiones(p, 'POST'), 1, 'la primera escritura ya se hizo');
    await new Promise(r => setTimeout(r, 2000));            /* 2,4 s despues: esta DENTRO de la pausa */
    assert.equal(peticiones(p, 'PATCH'), 0, 'la segunda escritura todavia no se envio: no hay ninguna peticion en vuelo');
    const e = await estado(p);
    assert.equal(e.operaciones, 1, 'la operacion sigue contada'); assert.equal(e.ocupado, true, 'y Actualizar sigue bloqueado pasado el margen de 1,5 s');
    assert.equal(await p.evaluar(js.ok + '.disabled'), true);
    assert.match(await textoBanner(p), /Hay un guardado en curso\. Espera a que termine para actualizar\./);
    await new Promise(r => setTimeout(r, 300)); await p.captura(sw('09-pausa-entre-escrituras-escritorio.png'));
    /* intentos de actualizar DURANTE la pausa: clic real, clic programatico y tecla */
    await p.clic('#lcUpd .lcu-ok');
    await p.evaluar(js.ok + '.click();true');
    await p.enfocar('#lcUpd .lcu-ok'); await p.tecla('Enter');
    await sleep(500);
    assert.equal(p.navegaciones, n0, 'no se recargo durante la pausa'); assert.equal(peticiones(p, 'PATCH'), 0);
    await p.esperar("__lcUpd.estado().operaciones===0", 8000, 'termina la operacion');
    assert.equal(peticiones(p, 'PATCH'), 1, 'se completaron las dos escrituras');
    await libre(p);
    await libre(p); assert.equal(await p.evaluar(js.ok + '.disabled'), false, 'se libera al terminar todo');
    await p.clic('#lcUpd .lcu-ok');
    await p.esperar("document.title.indexOf('[v2]')===0", 20000, 'version nueva');
    assert.equal(p.navegaciones, n0 + 1);
  } finally { await cerrar(s); }
});

test('si se pulsa Actualizar y la aplicacion empieza a guardar justo despues, la recarga espera a que TERMINE (tambien en una pausa larga)', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p); await irAGastos(p);
    const n0 = p.navegaciones;
    /* en el mismo instante: el clic (aun no hay operacion) y el boton de la aplicacion pasa a "Guardando..." (su indicador de operacion en curso) */
    await p.evaluar(js.ok + ".click();var b=document.getElementById('btnGuardarGasto');b.disabled=true;b.textContent='Guardando...';true");
    await p.esperar("navigator.serviceWorker.getRegistration().then(function(r){return !r.waiting;})", 8000, 'el service worker nuevo ya esta activo (la recarga esta pendiente)');
    await sleep(3000);                                       /* pausa larga: ninguna peticion, pero la aplicacion sigue "Guardando..." */
    assert.equal(p.navegaciones, n0, 'no se recargo en mitad de la operacion');
    assert.equal(await p.evaluar("document.title.indexOf('[v2]')"), -1);
    await p.evaluar("var b=document.getElementById('btnGuardarGasto');b.disabled=false;b.textContent='Registrar gasto';true");   /* la operacion termina */
    await p.esperar("document.title.indexOf('[v2]')===0", 20000, 'recarga al terminar');
    assert.equal(p.navegaciones, n0 + 1, 'una sola recarga, y solo despues de terminar');
  } finally { await cerrar(s); }
});

test('indicadores propios de la aplicacion: boton "Guardando...", _cotEnProceso y _convCot.fase bloquean mientras duren', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p);
    const bloqueado = () => p.evaluar(js.ok + '.disabled');
    /* boton deshabilitado con texto de progreso (como guardarGasto, doVenta, guardarProveedor...) */
    await irAGastos(p);
    await p.evaluar("var b=document.getElementById('btnGuardarGasto');b.disabled=true;b.textContent='Guardando...';true");
    await p.esperar(js.ok + '.disabled===true', 4000, 'bloqueado por boton Guardando...');
    await p.evaluar("var b=document.getElementById('btnGuardarGasto');b.disabled=false;b.textContent='Registrar gasto';true");
    await p.esperar(js.ok + '.disabled===false', 6000, 'liberado');
    /* un boton deshabilitado por VALIDACION (sin texto de progreso) no bloquea */
    await p.evaluar("var b=document.getElementById('btnGuardarGasto');b.disabled=true;true"); await sleep(1500);
    assert.equal(await bloqueado(), false, 'deshabilitado por validacion: no es una operacion');
    await p.evaluar("document.getElementById('btnGuardarGasto').disabled=false;true");
    /* conversion de cotizacion */
    await p.evaluar("_convCot={fase:'guardando'};true"); await p.esperar(js.ok + '.disabled===true', 4000, 'bloqueado por _convCot');
    await p.evaluar("_convCot=null;true"); await p.esperar(js.ok + '.disabled===false', 6000);
    await p.evaluar("_cotEnProceso['x']=true;true"); await p.esperar(js.ok + '.disabled===true', 4000, 'bloqueado por _cotEnProceso');
    await p.evaluar("delete _cotEnProceso['x'];true"); await p.esperar(js.ok + '.disabled===false', 6000);
  } finally { await cerrar(s); }
});

test('una operacion que sigue activa MAS DE 120 s sigue bloqueando (solo avisa de la demora) y se libera solo cuando termina', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p); await irAGastos(p); const n0 = p.navegaciones;
    const adelantar = ms => p.evaluar("(function(){var n=Date.now;var d=" + ms + ";Date.now=function(){return n.call(Date)+d;};})();true");   /* el reloj de la pagina avanza ms: la operacion lleva "mas de 120 s" */
    const sigueBloqueado = async (que) => {
      await sleep(900);                                                                     /* el aviso se repinta cada 700 ms */
      const e = await estado(p);
      assert.equal(e.ocupado, true, que + ': sigue ocupado'); assert.equal(await p.evaluar(js.ok + '.disabled'), true, que + ': Actualizar bloqueado');
      assert.match(await textoBanner(p), /tardando más de lo normal y sigue en curso/, que + ': avisa de la demora');
      await p.evaluar(js.ok + '.click();true'); await p.clic('#lcUpd .lcu-ok'); await sleep(400);
      assert.equal(p.navegaciones, n0, que + ': no se recargo');
    };
    /* a) escritura en vuelo (la base tarda) */
    const liberar = p.retenerEscrituras();
    await p.evaluar("window.__w=fetch(SB+'/rest/v1/gastos',{method:'POST',headers:H,body:'{}'});true");
    await p.esperar("__lcUpd.estado().ocupado===true", 3000);
    await adelantar(130000); await sigueBloqueado('escritura en vuelo');
    await p.captura(sw('12-operacion-mas-de-120s-sigue-bloqueada.png'));
    liberar(); await p.esperar("__lcUpd.estado().operaciones===0", 8000); await libre(p);
    /* b) boton "Guardando..." de la aplicacion */
    await p.evaluar("var b=document.getElementById('btnGuardarGasto');b.disabled=true;b.textContent='Guardando...';true");
    await p.esperar("__lcUpd.estado().ocupado===true", 3000); await adelantar(130000); await sigueBloqueado('boton Guardando...');
    await p.evaluar("var b=document.getElementById('btnGuardarGasto');b.disabled=false;b.textContent='Registrar gasto';true"); await libre(p);
    /* c) funcion de guardado seguida de principio a fin, en una pausa sin peticiones */
    await p.evaluar("window.operacionLarga=async function(){if(window.__nunca)await fetch(SB+'/rest/v1/gastos',{method:'POST',headers:H,body:'{}'});await new Promise(function(r){window.__fin=r;});};true"); await p.evaluar('__lcUpd.envolver()');
    await p.evaluar('window.__op=operacionLarga();true'); await p.esperar("__lcUpd.estado().operaciones===1", 3000);
    await adelantar(130000); await sigueBloqueado('operacion en una pausa');
    /* termina: se libera y entonces si se actualiza (una sola recarga) */
    await p.evaluar('window.__fin();true'); await p.esperar("__lcUpd.estado().operaciones===0", 5000); await libre(p);
    await p.clic('#lcUpd .lcu-ok'); await p.esperar("document.title.indexOf('[v2]')===0", 20000, 'version nueva al terminar');
    assert.equal(p.navegaciones, n0 + 1);
  } finally { await cerrar(s); }
});

test('cotizacion NUEVA sin guardar: agregar lineas avisa aunque ningun campo de texto cambie; vacia, o vuelta a vacia, no; Volver conserva; guardar o cancelar limpian; un fallo conserva', opciones, async () => {
  const s = await sesion();
  try {
    const { p } = s; await hayNueva(p);
    const hay = async () => (await sinGuardar(p)).some(x => /cotización nueva con productos sin guardar/.test(x));
    const nLineas = () => p.evaluar('cotItems.length'), cant = () => p.evaluar('JSON.stringify(cotItems.map(function(i){return [i.prod_id,i.cantidad];}))');
    await p.evaluar("INVENTARIO.push({id:'p9',nombre:'Ron',precio_venta:50000,uds_empaque:1,categoria:'Licores'},{id:'p8',nombre:'Vino',precio_venta:40000,uds_empaque:1,categoria:'Licores'});true");
    const abrir = async () => { await p.evaluar('abrirNuevaCotizacion();true'); await p.esperar("document.getElementById('modalCotizacion').style.display==='flex'", 5000, 'cotizacion nueva'); await sleep(1300); };
    const quitarTodas = async () => { while ((await nLineas()) > 0) await p.clic('#cotItemsList button[onclick="cotElimItem(0)"]'); };
    /* abrir vacia no avisa */
    await goCot(p); await abrir(); assert.deepEqual(await sinGuardar(p), [], 'abrir vacia no avisa');
    /* agregar una linea avisa, sin escribir en ningun campo */
    await p.evaluar("cotAddItem('p9','und');true"); assert.ok(await hay(), 'una linea: ' + JSON.stringify(await sinGuardar(p)));
    await p.captura(sw('13-cotizacion-nueva-con-productos.png'));
    /* agregar y quitar todas las lineas = estado inicial */
    await p.evaluar("cotAddItem('p8','und');true"); await quitarTodas();
    assert.deepEqual(await sinGuardar(p), [], 'sin lineas: vuelve al estado inicial');
    /* Volver conserva productos y cantidades */
    await p.evaluar("cotAddItem('p9','und');cotAddItem('p8','und');true"); await p.clic('#cotItemsList button[onclick="cotChgQty(0,1)"]');
    const antes = await cant(); assert.equal(await nLineas(), 2);
    await p.clic('#lcUpd .lcu-ok'); await p.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar y descartar'", 5000, 'advertencia');
    assert.match(await textoBanner(p), /cotización nueva con productos sin guardar/);
    await p.clic('#lcUpd .lcu-no'); await p.esperar("document.querySelector('#lcUpd .lcu-ok').textContent==='Actualizar'", 5000);
    assert.equal(await cant(), antes, 'Volver conserva productos y cantidades'); assert.ok(await hay());
    /* guardado FALLIDO conserva la advertencia */
    p.fallar = true; await p.clic('#modalCotizacion button[onclick="guardarCotizacion()"]');
    await p.esperar("__lcUpd.estado().operaciones===0", 8000, 'guardado fallido terminado');
    assert.equal(await p.evaluar("document.getElementById('modalCotizacion').style.display"), 'flex'); assert.ok(await hay(), 'tras fallar sigue avisando');
    /* guardado con EXITO la elimina */
    p.fallar = false; await p.clic('#modalCotizacion button[onclick="guardarCotizacion()"]');
    await p.esperar("document.getElementById('modalCotizacion').style.display==='none'", 8000, 'guardada y cerrada');
    await p.esperar("__lcUpd.estado().sinGuardar.length===0", 3000, 'limpio tras guardar');
    /* CANCELAR la elimina; y reabrir empieza vacia */
    await abrir(); await p.evaluar("cotAddItem('p9','und');true"); assert.ok(await hay());
    await p.clic('#modalCotizacion button[onclick="closeCotizacionModal()"]');
    await p.esperar("__lcUpd.estado().sinGuardar.length===0", 3000, 'limpio tras cancelar');
    await abrir(); assert.deepEqual(await sinGuardar(p), [], 'reabierta vacia: sin aviso');
  } finally { await cerrar(s); }
});
async function goCot(p) { await p.evaluar("goView('cotizaciones');true"); await sleep(500); }
