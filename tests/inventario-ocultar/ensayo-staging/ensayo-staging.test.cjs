'use strict';
/* Pruebas LOCALES de la preparacion del ensayo en staging (no se conectan a ningun Supabase):
   1) la foto de solo lectura (PRECHEQUEO_STAGING.sql) en un PostgreSQL temporal: instalar y revertir solo cambian las lineas COLUMNA| y PRIVILEGIO|*_oculto;
   2) la lista blanca del servidor local de ensayo (solo ens-ocu-*; sin DELETE salvo --permitir-retirada; sin tocar ensayos anteriores ens-*);
   3) el guion de datos ficticios contra un "staging" simulado en memoria: crea lo previsto, no sobrescribe lo ajeno, reinicia y retira solo lo suyo. */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), http = require('node:http');
const { disponible, iniciar, prepararBase, RAIZ } = require('../../hotfix-cotizaciones/pg/pg-temporal.cjs');
const { crearProxy, permitirEscritura, PREFIJO, MARCA_NOMBRE } = require('./servidor-ensayo-inventario.cjs');
const { ejecutar, PRODUCTOS } = require('./ensayo-staging-inventario-semilla.cjs');

/* ---------- 1) foto de solo lectura ---------- */
const SKIP = !disponible() && 'PostgreSQL portable no disponible';
let pg = null;
before(() => { if (!SKIP) { pg = iniciar(); prepararBase(pg, false); pg.sql("INSERT INTO inventario (id,nombre,categoria,precio_venta,stock,uds_sueltas,uds_empaque,id_licencia) VALUES ('a','A','x',1,0,0,1,'lacava'),('b','B','x',2,5,1,6,'lacava')"); } });
after(() => { if (pg) pg.detener(); });
const foto = () => { const r = pg.archivo(path.join(RAIZ, 'INVENTARIO_OCULTAR_PRODUCTOS_PRECHEQUEO_STAGING.sql')).split('\n').map(x => x.trim()).filter(Boolean); assert.equal(r[r.length - 1], 'RESULTADO|OK'); return r; };
const variable = l => l.startsWith('COLUMNA|') || /^PRIVILEGIO\|.*_oculto\|/.test(l);
const fijas = f => f.filter(l => !variable(l));

test('la foto de solo lectura: instalar y revertir solo cambian la columna; datos, politicas, disparadores y ACL quedan iguales', { skip: SKIP }, () => {
  const a = foto();
  assert.ok(a.includes('COLUMNA|oculto_existe|false')); assert.ok(a.some(l => /^DATOS\|inventario_filas\|2$/.test(l))); assert.ok(a.some(l => /^DATOS\|inventario_huella_sin_oculto\|[0-9a-f]{32}$/.test(l)));
  assert.ok(a.some(l => /^TABLA\|inventario_dueno\|.*usuario_es_dueno_o_miembro=/.test(l)));
  pg.archivo(path.join(RAIZ, 'INVENTARIO_OCULTAR_PRODUCTOS.sql'));
  const d = foto();
  assert.ok(d.includes('COLUMNA|oculto_existe|true')); assert.ok(d.includes('COLUMNA|oculto_definicion|boolean|nullable=NO|default=false'));
  assert.deepEqual(fijas(d), fijas(a), 'solo cambian las lineas de la columna');
  assert.ok(d.some(l => /^PRIVILEGIO\|authenticated_oculto\|SELECT=(true|false),UPDATE=(true|false)$/.test(l)), 'informa los privilegios de la columna');
  pg.archivo(path.join(RAIZ, 'INVENTARIO_OCULTAR_PRODUCTOS_REVERTIR.sql'));
  const r = foto();
  assert.deepEqual(r, a, 'revertir deja la foto identica a la inicial');
});
test('la foto es de solo lectura: no puede escribir ni siquiera una fila', { skip: SKIP }, () => {
  const antes = pg.sql('SELECT md5(string_agg(i::text, $$|$$ ORDER BY id)) FROM inventario i').out;
  foto();
  assert.equal(pg.sql('SELECT md5(string_agg(i::text, $$|$$ ORDER BY id)) FROM inventario i').out, antes);
  const sqlFoto = fs.readFileSync(path.join(RAIZ, 'INVENTARIO_OCULTAR_PRODUCTOS_PRECHEQUEO_STAGING.sql'), 'utf8');
  assert.match(sqlFoto, /BEGIN TRANSACTION READ ONLY;/); assert.match(sqlFoto, /ROLLBACK;\s*$/);
  assert.equal(/\b(INSERT|UPDATE|DELETE|ALTER|DROP|CREATE|GRANT|REVOKE|TRUNCATE)\b/i.test(sqlFoto.split('\n').filter(l => !l.trim().startsWith('--')).join('\n').replace(/'[^']*'/g, "''")), false, 'no contiene sentencias que escriban');
});

/* ---------- 2) lista blanca del servidor ---------- */
const cuerpo = o => Buffer.from(JSON.stringify(o));
const prod = (id, extra) => Object.assign({ id, nombre: 'X ' + MARCA_NOMBRE }, extra);
test('lista blanca: solo escrituras sobre ens-ocu-*; nada sobre productos reales ni sobre los ensayos anteriores (ens-*)', () => {
  const ok = (m, r, q, c, o) => assert.equal(permitirEscritura(m, r, q || '', c || Buffer.alloc(0), o), null, m + ' ' + r + ' ' + q);
  const no = (m, r, q, c, o) => assert.notEqual(permitirEscritura(m, r, q || '', c || Buffer.alloc(0), o), null, 'debia bloquear ' + m + ' ' + r + ' ' + q);
  ok('POST', '/rest/v1/inventario', '', cuerpo([prod('ens-ocu-cero')]));
  no('POST', '/rest/v1/inventario', '', cuerpo([prod('ens-cerveza6')]));                                  /* ensayo anterior */
  no('POST', '/rest/v1/inventario', '', cuerpo([prod('prod_123')]));                                      /* producto real */
  no('POST', '/rest/v1/inventario', '', cuerpo([{ id: 'ens-ocu-x', nombre: 'sin marca' }]));              /* sin la marca en el nombre */
  no('POST', '/rest/v1/inventario', '', cuerpo([prod('ens-ocu-a'), prod('prod_1')]));                    /* mezcla */
  ok('PATCH', '/rest/v1/inventario', 'id=eq.ens-ocu-cero&id_licencia=eq.lacava&stock=eq.0&uds_sueltas=eq.0', cuerpo({ oculto: true }));
  no('PATCH', '/rest/v1/inventario', 'id=eq.prod_123', cuerpo({ oculto: true }));
  no('PATCH', '/rest/v1/inventario', 'id=eq.ens-cerveza6', cuerpo({ stock: 0 }));
  no('PATCH', '/rest/v1/inventario', 'id=neq.ens-ocu-x', cuerpo({ stock: 0 }));                          /* sin ancla de id */
  no('PATCH', '/rest/v1/inventario', 'nombre=like.*ens-ocu-*', cuerpo({ stock: 0 }));
  no('DELETE', '/rest/v1/inventario', 'id=eq.ens-ocu-cero');                                             /* sin --permitir-retirada */
  ok('DELETE', '/rest/v1/inventario', 'id=eq.ens-ocu-cero&stock=eq.0&uds_sueltas=eq.0', undefined, { permitirRetirada: true });
  no('DELETE', '/rest/v1/inventario', 'id=eq.prod_123', undefined, { permitirRetirada: true });
  no('DELETE', '/rest/v1/inventario', 'id=eq.ens-cerveza6', undefined, { permitirRetirada: true });
  ok('POST', '/rest/v1/inventario_bodega', '', cuerpo([{ prod_id: 'ens-ocu-bodega', stock: 4 }]));
  no('POST', '/rest/v1/inventario_bodega', '', cuerpo([{ prod_id: 'prod_123', stock: 4 }]));
  ok('PATCH', '/rest/v1/inventario_bodega', 'prod_id=eq.ens-ocu-bodega', cuerpo({ stock: 0 }));
  no('PATCH', '/rest/v1/inventario_bodega', 'id_bodega=eq.x', cuerpo({ stock: 0 }));
  no('DELETE', '/rest/v1/inventario_bodega', 'prod_id=eq.ens-ocu-bodega');
  ok('POST', '/rest/v1/producto_presentaciones', '', cuerpo([{ id_producto: 'ens-ocu-entrada', tipo_presentacion: 'unidad' }]));
  no('POST', '/rest/v1/producto_presentaciones', '', cuerpo([{ id_producto: 'prod_1' }]));
  ok('POST', '/rest/v1/bodegas', '', cuerpo([{ id_licencia: 'x', nombre: 'Bodega (ENSAYO)' }]));
  no('POST', '/rest/v1/bodegas', '', cuerpo([{ id_licencia: 'x', nombre: 'Bodega real' }]));
  no('PATCH', '/rest/v1/bodegas', 'id=eq.1', cuerpo({ nombre: 'x' }));
  ok('POST', '/rest/v1/rpc/lacava_mi_sesion', '', cuerpo({}));
  no('POST', '/rest/v1/rpc/convertir_cotizacion_atomica', '', cuerpo({}));
  for (const t of ['ventas', 'compras', 'cotizaciones', 'cartera', 'caja_sesiones', 'gastos', 'licencias', 'cotizacion_conversiones', 'clientes_frecuentes']) no('POST', '/rest/v1/' + t, '', cuerpo([{ id: 'ens-ocu-x' }]));
});

test('el servidor sirve la copia local del dashboard apuntando solo a si mismo y bloquea lo no permitido', async () => {
  const llamadas = [];
  const p = crearProxy({ puerto: 0, base: 'https://upstream.invalido', credenciales: async () => ({ apikey: 'x', Authorization: 'Bearer y' }),
    fetch: async (u, o) => { llamadas.push(o.method + ' ' + u); return { status: 200, headers: new Map([['content-type', 'application/json']]), arrayBuffer: async () => Buffer.from('[]') }; } });
  await new Promise(ok => p.servidor.listen(0, '127.0.0.1', ok)); const puerto = p.servidor.address().port;
  try {
    const pedir = (metodo, ruta, c) => new Promise((ok, no) => { const r = http.request({ host: '127.0.0.1', port: puerto, path: ruta, method: metodo, headers: { 'content-type': 'application/json' } }, res => { const t = []; res.on('data', d => t.push(d)); res.on('end', () => ok({ status: res.statusCode, texto: Buffer.concat(t).toString('utf8') })); }); r.on('error', no); if (c) r.write(c); r.end(); });
    const h = await pedir('GET', '/');
    assert.equal(h.status, 200); assert.match(h.texto, new RegExp("var SB='http://127\\.0\\.0\\.1:" + 0 + "';|var SB='http://127\\.0\\.0\\.1:\\d+';")); assert.equal(/\.supabase\.co/.test(h.texto.replace(/https:\/\/(?:fonts|wa)\.[a-z.]+/g, '')), false, 'el HTML no contiene ninguna URL de supabase.co');
    assert.equal((await pedir('PATCH', '/rest/v1/inventario?id=eq.prod_real', '{"oculto":true}')).status, 403, 'producto real: bloqueado');
    assert.equal(llamadas.length, 0, 'lo bloqueado nunca llega a staging');
    assert.equal((await pedir('PATCH', '/rest/v1/inventario?id=eq.ens-ocu-cero', '{"oculto":true}')).status, 200);
    assert.equal((await pedir('GET', '/rest/v1/inventario?select=id')).status, 200);
    assert.deepEqual(llamadas, ['PATCH https://upstream.invalido/rest/v1/inventario?id=eq.ens-ocu-cero', 'GET https://upstream.invalido/rest/v1/inventario?select=id']);
  } finally { p.servidor.close(); }
});

/* ---------- 3) guion de datos ficticios contra un staging simulado ---------- */
function stagingSimulado(extraInv) {
  const db = { inv: (extraInv || []).slice(), bod: [], bodegas: [], log: [] };
  const filtro = (q, campo) => { const m = new RegExp('(?:^|&)' + campo + '=eq\\.([^&]+)').exec(q); return m ? decodeURIComponent(m[1]) : null; };
  const enLista = (q, campo) => { const m = new RegExp('(?:^|&)' + campo + '=in\\.\\(([^)]*)\\)').exec(decodeURIComponent(q)); return m ? m[1].split(',').map(s => s.replace(/"/g, '')) : null; };
  const f = async (url, init) => {
    const u = new URL(url), q = u.search.replace(/^\?/, ''), m = (init && init.method) || 'GET', ruta = u.pathname.replace('/rest/v1/', '');
    const body = init && init.body ? JSON.parse(init.body.toString()) : null; const r = (st, j) => ({ status: st, headers: new Map(), arrayBuffer: async () => Buffer.from(JSON.stringify(j)), text: async () => JSON.stringify(j), json: async () => j });
    if (m !== 'GET' && !ruta.startsWith('rpc/')) db.log.push(m + ' ' + ruta + '?' + decodeURIComponent(q));
    if (ruta === 'rpc/lacava_mi_sesion') return r(200, { licencia: 'lic-test', rol: 'admin' });
    if (ruta === 'inventario') {
      if (m === 'GET') { const ids = enLista(q, 'id'); return r(200, db.inv.filter(p => !ids || ids.includes(p.id))); }
      if (m === 'POST') { body.forEach(p => db.inv.push(Object.assign({}, p))); return r(201, body); }
      if (m === 'PATCH') { const id = filtro(q, 'id'); db.inv.filter(p => p.id === id).forEach(p => Object.assign(p, body)); return r(200, db.inv.filter(p => p.id === id)); }
      if (m === 'DELETE') { const id = filtro(q, 'id'); const antes = db.inv.length; db.inv = db.inv.filter(p => !(p.id === id && p.stock === 0 && p.uds_sueltas === 0)); return r(200, antes - db.inv.length ? [{ id }] : []); }
    }
    if (ruta === 'bodegas') { if (m === 'GET') return r(200, db.bodegas); if (m === 'POST') { const b = [Object.assign({ id: 'bod-1' }, body[0])]; db.bodegas.push(b[0]); return r(201, b); } }
    if (ruta === 'inventario_bodega') {
      if (m === 'GET') { const ids = enLista(q, 'prod_id'); return r(200, db.bod.filter(x => !ids || ids.includes(x.prod_id))); }
      if (m === 'POST') { body.forEach(x => db.bod.push(Object.assign({ id: 'b' + db.bod.length }, x))); return r(201, body); }
      if (m === 'PATCH') { const id = filtro(q, 'prod_id'); db.bod.filter(x => x.prod_id === id).forEach(x => Object.assign(x, body)); return r(200, []); }
      if (m === 'DELETE') { const id = filtro(q, 'prod_id'); db.bod = db.bod.filter(x => x.prod_id !== id); return r(200, []); }
    }
    return r(404, { message: 'no simulado: ' + ruta });
  };
  return { db, f };
}
async function conServidor(sim, opciones, fn) {
  const p = crearProxy(Object.assign({ puerto: 0, base: 'https://staging.simulado', credenciales: async () => ({}), fetch: sim.f }, opciones || {}));
  await new Promise(ok => p.servidor.listen(0, '127.0.0.1', ok)); const base = 'http://127.0.0.1:' + p.servidor.address().port;
  try { return await fn(base); } finally { p.servidor.close(); }
}
test('el guion crea los 5 productos y la bodega previstos, es idempotente y deja ens-ocu-bodega con 4 en bodega', async () => {
  const sim = stagingSimulado();
  /* el proxy responde /__guarda con proyecto y ensayo; el guion exige ambos */
  await conServidor(sim, {}, async base => {
    const r = await ejecutar({ base }); assert.equal(r.productos.length, 5);
    const por = Object.fromEntries(sim.db.inv.map(p => [p.id, p]));
    assert.deepEqual(Object.keys(por).sort(), PRODUCTOS.map(p => p.id).sort()); assert.ok(sim.db.inv.every(p => p.nombre.includes(MARCA_NOMBRE) && p.id.startsWith(PREFIJO) && p.id_licencia === 'lic-test'));
    assert.equal(por['ens-ocu-cero'].stock, 0); assert.equal(por['ens-ocu-stock'].stock, 5); assert.equal(por['ens-ocu-sueltas'].uds_sueltas, 3); assert.equal(por['ens-ocu-sueltas'].uds_empaque, 6);
    assert.equal(por['ens-ocu-entrada'].oculto, true); assert.equal(por['ens-ocu-cero'].oculto, false);
    assert.deepEqual(sim.db.bod.map(x => [x.prod_id, x.stock]), [['ens-ocu-bodega', 4]]); assert.equal(sim.db.bodegas.length, 1);
    const escrituras = sim.db.log.length; await ejecutar({ base }); assert.equal(sim.db.log.length, escrituras, 'repetir no escribe nada mas');
    assert.equal(sim.db.log.filter(l => !/^(POST|PATCH|DELETE) (inventario|inventario_bodega|bodegas)\?/.test(l)).length, 0, 'solo se escribe en inventario, inventario_bodega y la bodega de ensayo');
  });
});
test('el guion no sobrescribe lo ajeno, reinicia solo lo suyo y retira solo lo suyo', async () => {
  const real = { id: 'prod_real', nombre: 'Producto real', stock: 9, uds_sueltas: 0 }, anterior = { id: 'ens-cerveza6', nombre: 'Cerveza x6 (ENSAYO)', stock: 100, uds_sueltas: 2 };
  const sim = stagingSimulado([real, anterior]);
  await conServidor(sim, {}, async base => {
    await ejecutar({ base });
    /* el ensayo cambia cosas... y se reinicia */
    const cero = sim.db.inv.find(p => p.id === 'ens-ocu-cero'); cero.oculto = true; cero.stock = 3; sim.db.inv.find(p => p.id === 'ens-ocu-bodega').stock = 7;
    await ejecutar({ base, reiniciar: true });
    assert.equal(cero.oculto, false); assert.equal(cero.stock, 0); assert.equal(sim.db.inv.find(p => p.id === 'ens-ocu-bodega').stock, 0);
    assert.deepEqual([sim.db.inv.find(p => p.id === 'prod_real').stock, sim.db.inv.find(p => p.id === 'ens-cerveza6').stock], [9, 100], 'lo real y los ensayos anteriores no cambian');
    /* sin --permitir-retirada el servidor no deja borrar */
    await ejecutar({ base, retirar: true });
    assert.equal(sim.db.inv.filter(p => p.id.startsWith('ens-ocu-')).length, 5, 'sin --permitir-retirada el servidor no deja borrar nada');
  });
  await conServidor(sim, { permitirRetirada: true }, async base => {
    await ejecutar({ base, retirar: true });
    assert.deepEqual(sim.db.inv.map(p => p.id).sort(), ['ens-cerveza6', 'prod_real'], 'quedan solo los productos ajenos');
    assert.equal(sim.db.bod.length, 0);
  });
  /* un id previsto ya existente y que no es de ensayo detiene todo */
  const sim2 = stagingSimulado([{ id: 'ens-ocu-cero', nombre: 'Producto de un cliente', stock: 1, uds_sueltas: 0 }]);
  await conServidor(sim2, {}, async base => { await assert.rejects(ejecutar({ base }), /NO es de ensayo/); assert.equal(sim2.db.log.length, 0, 'no se escribio nada'); });
});
