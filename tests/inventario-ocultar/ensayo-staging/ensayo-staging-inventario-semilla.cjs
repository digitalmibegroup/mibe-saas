'use strict';
/* DATOS FICTICIOS del ensayo "ocultar productos en Inventario" en el staging ca10112ba2. Habla SOLO con el servidor local de ensayo
   (servidor-ensayo-inventario.cjs), que inyecta la sesion: este guion no maneja credenciales. Productos identificables: id "ens-ocu-*" y nombre
   "(ENSAYO OCULTAR)". NO sobrescribe nada ajeno: si un id previsto ya existe y no es de ensayo, se detiene. No toca productos reales ni los ensayos anteriores (ens-*).
   Uso (con el servidor abierto y la columna instalada):
     node ensayo-staging-inventario-semilla.cjs --base http://127.0.0.1:5192 [--estado]      crea lo que falte y muestra el estado
     node ensayo-staging-inventario-semilla.cjs --base ... --reiniciar                        deja los 5 productos y la bodega en su estado inicial (solo ens-ocu-*)
     node ensayo-staging-inventario-semilla.cjs --base ... --retirar                          (servidor con --permitir-retirada) borra SOLO los ens-ocu-* y sus filas de bodega
   Resultado: tabla en pantalla; el estado se compara con lo ESPERADO tras cada paso del plan (ver PLAN_ENSAYO_INVENTARIO_OCULTAR_EN_STAGING.md). */
const { PREFIJO, MARCA_NOMBRE } = require('./servidor-ensayo-inventario.cjs');

const P = (suf, nombre, extra) => Object.assign({ id: PREFIJO + suf, nombre: nombre + ' ' + MARCA_NOMBRE, categoria: 'Ensayo ocultar', precio_venta: 10000, precio_costo: 6000,
  stock: 0, stock_min: 2, empaque: 'unidad', uds_empaque: 1, uds_sueltas: 0, oculto: false }, extra);
/* estado inicial de cada caso del plan */
const PRODUCTOS = [
  P('cero', 'Sin existencias', {}),                                                              /* ocultar, restaurar, persistencia */
  P('stock', 'Con stock', { stock: 5 }),                                                         /* rechazo: stock en el principal */
  P('sueltas', 'Solo sueltas', { empaque: 'sixpack', uds_empaque: 6, uds_sueltas: 3 }),          /* rechazo: unidades sueltas */
  P('bodega', 'Solo en bodega', {}),                                                             /* rechazo: existencias en bodega (4 en la bodega) */
  P('entrada', 'Oculto para entrada', { oculto: true })                                          /* entrada de stock: reaparece y se limpia la marca */
];
const BODEGA_STOCK = { [PREFIJO + 'bodega']: 4 };

async function ejecutar({ base, log, fetchFn, reiniciar, retirar }) {
  const f = fetchFn || fetch, out = log || (() => {});
  async function api(metodo, ruta, cuerpo) {
    const r = await f(base + '/rest/v1/' + ruta, { method: metodo, headers: { 'content-type': 'application/json', Prefer: 'return=representation' }, body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo) });
    const txt = await r.text(); let json = null; try { json = txt ? JSON.parse(txt) : null; } catch (e) { /* no JSON */ }
    return { status: r.status, json, texto: txt };
  }
  const abortar = m => { throw new Error(m); };
  const g = await (await f(base + '/__guarda')).json().catch(() => null);
  if (!g || g.proyecto !== 'ca10112ba2' || g.ensayo !== 'ocultar-inventario') abortar('El servidor no confirma el ensayo de ocultar inventario en el staging ca10112ba2. Detenido.');
  const ses = await api('POST', 'rpc/lacava_mi_sesion', {});
  if (ses.status !== 200 || !ses.json || !ses.json.licencia) abortar('La sesion del usuario ficticio no es valida (HTTP ' + ses.status + '). Detenido.');
  const LIC = ses.json.licencia;
  out('Licencia "' + LIC + '", rol ' + ses.json.rol);
  const col = await api('GET', 'inventario?select=id,oculto&limit=1');
  if (col.status !== 200) abortar('La columna inventario.oculto no esta instalada (HTTP ' + col.status + '). Instala primero con ENSAYO-OCULTAR-INVENTARIO-EN-STAGING.ps1 -Accion Instalar.');

  const ids = PRODUCTOS.map(p => p.id);
  const lista = '(' + ids.map(i => '%22' + i + '%22').join(',') + ')';
  const leer = () => api('GET', 'inventario?id=in.' + lista + '&select=id,nombre,stock,uds_sueltas,uds_empaque,oculto&order=id.asc');
  let ex = await leer(); if (ex.status !== 200) abortar('No se pudo leer el inventario (HTTP ' + ex.status + ').');
  for (const p of ex.json) if (!String(p.nombre || '').includes(MARCA_NOMBRE)) abortar('El id ' + p.id + ' ya existe y NO es de ensayo. Detenido: no se sobrescribe.');

  if (retirar) {
    out('RETIRADA de los productos ens-ocu-* (solo ellos)');
    for (const id of ids) {
      const b = await api('DELETE', 'inventario_bodega?prod_id=eq.' + id); out('  bodega de ' + id + ': HTTP ' + b.status);
      await api('PATCH', 'inventario?id=eq.' + id, { stock: 0, uds_sueltas: 0 });
      const d = await api('DELETE', 'inventario?id=eq.' + id + '&stock=eq.0&uds_sueltas=eq.0'); out('  producto ' + id + ': HTTP ' + d.status);
    }
    ex = await leer(); out('Quedan ' + ex.json.length + ' productos ens-ocu-*.'); return { retirados: ids.length - ex.json.length, quedan: ex.json };
  }

  /* bodega (solo si staging aun no tiene una) */
  const bod = await api('GET', 'bodegas?id_licencia=eq.' + encodeURIComponent(LIC) + '&select=id,nombre');
  if (bod.status !== 200) abortar('No se pudo leer bodegas (HTTP ' + bod.status + ').');
  let bodegaId = bod.json[0] && bod.json[0].id;
  if (!bodegaId) {
    const c = await api('POST', 'bodegas', [{ id_licencia: LIC, nombre: 'Bodega (ENSAYO)' }]);
    if (c.status !== 201) abortar('No se pudo crear la bodega de ensayo (HTTP ' + c.status + ' ' + ((c.json && c.json.message) || '') + ').');
    bodegaId = c.json[0].id; out('Bodega de ensayo creada (staging no tenia ninguna).');
  } else out('Se usa la bodega existente de staging (no se crea ni se modifica).');

  const existentes = Object.fromEntries(ex.json.map(p => [p.id, p]));
  const nuevos = PRODUCTOS.filter(p => !existentes[p.id]).map(p => Object.assign({ id_licencia: LIC }, p));
  if (nuevos.length) {
    const c = await api('POST', 'inventario', nuevos);
    if (c.status !== 201) abortar('No se pudieron crear los productos (HTTP ' + c.status + ' ' + ((c.json && c.json.message) || '') + ').');
    out('Productos creados: ' + nuevos.map(p => p.id).join(', '));
  }
  if (reiniciar) {
    for (const p of PRODUCTOS) {
      if (!existentes[p.id]) continue;
      const r = await api('PATCH', 'inventario?id=eq.' + p.id, { stock: p.stock, uds_sueltas: p.uds_sueltas, oculto: p.oculto });
      out('  reiniciado ' + p.id + ': HTTP ' + r.status);
    }
  }
  /* filas de bodega del ensayo */
  const br = await api('GET', 'inventario_bodega?prod_id=in.' + lista + '&select=id,prod_id,stock,uds_sueltas');
  const filasBod = Object.fromEntries((br.json || []).map(x => [x.prod_id, x]));
  for (const [pid, stock] of Object.entries(BODEGA_STOCK)) {
    if (!filasBod[pid]) { const c = await api('POST', 'inventario_bodega', [{ id_licencia: LIC, id_bodega: bodegaId, prod_id: pid, stock, uds_sueltas: 0 }]); out('  bodega ' + pid + ' = ' + stock + ': HTTP ' + c.status); }
    else if (reiniciar) { const r = await api('PATCH', 'inventario_bodega?prod_id=eq.' + pid, { stock, uds_sueltas: 0 }); out('  bodega ' + pid + ' reiniciada: HTTP ' + r.status); }
  }
  const fin = await leer(); const finB = await api('GET', 'inventario_bodega?prod_id=in.' + lista + '&select=prod_id,stock,uds_sueltas');
  out('\nEstado de los productos de ensayo:');
  for (const p of fin.json) { const b = (finB.json || []).find(x => x.prod_id === p.id); out('  ' + p.id.padEnd(18) + ' principal=' + p.stock + ' sueltas=' + p.uds_sueltas + ' bodega=' + (b ? b.stock + '/' + b.uds_sueltas : '-') + ' oculto=' + p.oculto); }
  return { productos: fin.json, bodega: finB.json, licencia: LIC };
}

if (require.main === module) {
  const i = process.argv.indexOf('--base'); const base = i > 0 ? process.argv[i + 1] : null;
  if (!base || !/^http:\/\/127\.0\.0\.1:\d+$/.test(base)) { console.error('Indica --base http://127.0.0.1:<puerto> (el servidor local de ensayo).'); process.exit(2); }
  ejecutar({ base, log: m => console.log(m), reiniciar: process.argv.includes('--reiniciar'), retirar: process.argv.includes('--retirar') }).catch(e => { console.error('Error: ' + e.message); process.exit(3); });
}
module.exports = { ejecutar, PRODUCTOS, BODEGA_STOCK };
