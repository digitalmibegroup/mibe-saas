'use strict';
/* Base simulada en memoria con la forma de PostgREST/Supabase y las restricciones REALES
   leidas del catalogo de produccion (16-nov-2026): columnas, claves primarias, unicos,
   checks y claves foraneas de las tablas que toca el hotfix. No se conecta a nada.
   Permite inyectar fallos por peticion: respuesta perdida, 5xx tras aplicar, 4xx, etc. */
const crypto = require('node:crypto');

const COLS = {
  clientes_frecuentes: ['id','created_at','id_licencia','nombre','whatsapp','puntos','total_compras','num_pedidos','ultima_compra','direccion','detalle'],
  cotizaciones: ['id','id_licencia','numero_local','numero','cliente_nombre','cliente_whatsapp','estado','items','total','fecha_creacion','fecha_vencimiento','venta_id','created_at','updated_at'],
  ventas: ['id','created_at','id_cliente','numero_venta','cliente_nombre','cliente_whatsapp','subtotal','descuento','total','metodo_pago','estado','notas','puntos_ganados','domicilio','direccion_entrega','detalle_entrega','es_promocion','abono','saldo_pendiente','fecha_vencimiento_cartera','cotizacion_id'],
  detalle_ventas: ['id','created_at','venta_id','producto_nombre','categoria','cantidad','precio_unitario','precio_total','prod_id','es_unidad','uds_empaque'],
  cartera: ['id','id_licencia','venta_id','cliente_id','numero_venta','cliente_nombre','cliente_whatsapp','total','saldo_pendiente','fecha_vencimiento','fecha_creacion','estado_cartera','created_at','updated_at'],
  cartera_abonos: ['id','id_licencia','cartera_id','venta_id','monto','fecha','registrado_por','created_at','medio_pago'],
  inventario: null /* columnas libres */
};
const UNICOS = {
  clientes_frecuentes: [['clientes_frecuentes_pkey', ['id']]],
  cotizaciones: [['cotizaciones_pkey', ['id']], ['cotizaciones_id_licencia_numero_local_key', ['id_licencia', 'numero_local']]],
  ventas: [['ventas_pkey', ['id']], ['idx_ventas_cotizacion_unica', ['cotizacion_id'], r => r.cotizacion_id != null]],
  detalle_ventas: [['detalle_ventas_pkey', ['id']]],
  cartera: [['cartera_pkey', ['id']], ['cartera_venta_id_unique', ['venta_id']]],
  cartera_abonos: [['cartera_abonos_pkey', ['id']]],
  inventario: [['inventario_pkey', ['id']]]
};
const FKS = {
  detalle_ventas: [['detalle_ventas_venta_id_fkey', 'venta_id', 'ventas']],
  cartera: [['cartera_venta_id_fkey', 'venta_id', 'ventas']],
  cartera_abonos: [['cartera_abonos_cartera_fkey', 'cartera_id', 'cartera']],
  ventas: [['ventas_cotizacion_id_fkey', 'cotizacion_id', 'cotizaciones']],
  cotizaciones: [['cotizaciones_venta_id_fkey', 'venta_id', 'ventas']]
};
const TS = new Set(['created_at','updated_at','fecha','fecha_creacion','fecha_vencimiento','fecha_vencimiento_cartera','ultima_compra']);

function tsCanon(v) {
  const m = String(v).trim().match(/^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}(?::?\d{2})?)?$/);
  if (!m) return null;
  const frac = ((m[3] || '') + '000000').slice(0, 6);
  const off = m[4] || 'Z';
  if (off === 'Z' || /^[+-]00(:?00)?$/.test(off)) return m[1] + 'T' + m[2] + '.' + frac;
  const d = new Date(m[1] + 'T' + m[2] + (off.length === 3 ? off + ':00' : off));
  return d.toISOString().slice(0, 19) + '.' + frac;
}
/* Postgres devuelve timestamptz como '...ffffff+00:00' */
function tsPg(v) { const c = tsCanon(v); return c ? c + '+00:00' : v; }
function ahoraPg() { return tsPg(new Date().toISOString()); }

function likeARegex(p) {
  let r = '';
  for (let i = 0; i < p.length; i++) {
    const c = p[i];
    if (c === '\\' && i + 1 < p.length) { r += p[++i].replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); continue; }
    if (c === '*' || c === '%') r += '.*'; else if (c === '_') r += '.'; else r += c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp('^' + r + '$', 'is');
}
function parseIn(v) {
  const inner = v.replace(/^\(/, '').replace(/\)$/, '');
  const out = []; let cur = '', q = false;
  for (const ch of inner) { if (ch === '"') { q = !q; continue; } if (ch === ',' && !q) { out.push(cur); cur = ''; continue; } cur += ch; }
  if (cur.length) out.push(cur);
  return out;
}
function cumple(row, col, expr) {
  const dot = expr.indexOf('.');
  const op = expr.slice(0, dot), val = expr.slice(dot + 1), cel = row[col];
  if (op === 'is') { if (val === 'null') return cel == null; if (val === 'true') return cel === true; if (val === 'false') return cel === false; }
  if (op === 'eq') {
    if (cel == null) return false;
    if (TS.has(col)) return tsCanon(cel) === tsCanon(val);
    if (typeof cel === 'number') return cel === Number(val);
    return String(cel) === val;
  }
  if (op === 'neq') return cel == null ? false : String(cel) !== val;
  if (op === 'ilike') return cel != null && likeARegex(val).test(String(cel));
  if (op === 'in') return cel != null && parseIn(val).includes(String(cel));
  if (['gt', 'gte', 'lt', 'lte'].includes(op)) {
    if (cel == null) return false;
    const x = TS.has(col) ? tsCanon(cel) : Number(cel), y = TS.has(col) ? tsCanon(val) : Number(val);
    return op === 'gt' ? x > y : op === 'gte' ? x >= y : op === 'lt' ? x < y : x <= y;
  }
  if (op === 'gt') return Number(cel) > Number(val);
  if (op === 'lt') return Number(cel) < Number(val);
  throw new Error('operador no soportado: ' + op);
}
const RESERVADOS = new Set(['select', 'order', 'limit', 'offset', 'on_conflict']);

function crearBase(seed) {
  const T = {}; for (const t of Object.keys(COLS)) T[t] = [];
  let numeroVenta = 1000;
  const base = { T, log: [], fallas: [], contadores: {}, escrituras: 0 };
  const clon = o => JSON.parse(JSON.stringify(o));

  function defaults(t, r) {
    r = Object.assign({}, r);
    if (r.id == null && t !== 'inventario') r.id = crypto.randomUUID();
    if (COLS[t] && COLS[t].includes('created_at') && r.created_at == null) r.created_at = ahoraPg();
    if (t === 'cotizaciones' || t === 'cartera') { if (r.updated_at == null) r.updated_at = ahoraPg(); }
    if (t === 'ventas') {
      if (r.numero_venta == null) r.numero_venta = ++numeroVenta;
      r.id_cliente = r.id_cliente ?? 'lacava'; r.metodo_pago = r.metodo_pago ?? 'efectivo'; r.estado = r.estado ?? 'completada';
      r.abono = r.abono ?? 0; r.saldo_pendiente = r.saldo_pendiente ?? 0; r.descuento = r.descuento ?? 0; r.domicilio = r.domicilio ?? 0;
    }
    if (t === 'detalle_ventas') { r.es_unidad = r.es_unidad ?? false; r.uds_empaque = r.uds_empaque ?? 1; }
    if (t === 'cartera') { r.fecha_creacion = r.fecha_creacion ?? ahoraPg(); r.estado_cartera = r.estado_cartera ?? 'activa'; }
    if (t === 'cartera_abonos') { r.fecha = r.fecha ?? ahoraPg(); r.registrado_por = r.registrado_por ?? 'admin'; }
    if (t === 'clientes_frecuentes') { r.id_licencia = r.id_licencia ?? 'lacava'; }
    for (const k of Object.keys(r)) if (TS.has(k) && r[k] != null) r[k] = tsPg(r[k]);
    return r;
  }
  function error(status, code, message) { return { status, body: JSON.stringify({ code, message, details: null, hint: null }) }; }
  function validarColumnas(t, r) {
    if (!COLS[t]) return null;
    for (const k of Object.keys(r)) if (!COLS[t].includes(k)) return error(400, 'PGRST204', `Could not find the '${k}' column of '${t}' in the schema cache`);
    return null;
  }
  function validarFila(t, r, todas) {
    if (t === 'cartera_abonos' && !(Number(r.monto) > 0)) return error(400, '23514', 'new row violates check constraint "cartera_abonos_monto_chk"');
    if (t === 'cartera' && !['activa', 'pagada'].includes(r.estado_cartera)) return error(400, '23514', 'violates check constraint "cartera_estado_chk"');
    if (t === 'cartera' && Number(r.saldo_pendiente) < 0) return error(400, '23514', 'violates check constraint "cartera_saldo_chk"');
    if (t === 'cotizaciones' && !['pendiente', 'aprobada', 'rechazada', 'convertida'].includes(r.estado)) return error(400, '23514', 'violates check constraint "cotizaciones_estado_check"');
    for (const [nombre, col, ref] of (FKS[t] || [])) if (r[col] != null && !T[ref].some(x => x.id === r[col])) return error(409, '23503', `insert or update on table "${t}" violates foreign key constraint "${nombre}"`);
    for (const [nombre, cols, cond] of (UNICOS[t] || [])) {
      if (cond && !cond(r)) continue;
      const clave = cols.map(c => String(r[c])).join('|');
      if (todas.some(x => x !== r && (!cond || cond(x)) && cols.map(c => String(x[c])).join('|') === clave)) return error(409, '23505', `duplicate key value violates unique constraint "${nombre}"`);
    }
    return null;
  }
  function filtrar(t, params) {
    let filas = T[t];
    for (const [k, v] of params) { if (RESERVADOS.has(k)) continue; filas = filas.filter(r => cumple(r, k, v)); }
    return filas;
  }
  function manejar(method, url, bodyStr) {
    const u = new URL(url);
    const m = u.pathname.match(/^\/rest\/v1\/([a-z_]+)$/);
    if (!m) return error(404, 'PGRST', 'ruta no simulada ' + u.pathname);
    const t = m[1];
    if (!T[t]) return method === 'GET' ? { status: 200, body: '[]' } : error(404, '42P01', 'tabla no simulada ' + t);
    const params = [...u.searchParams.entries()];
    if (method === 'GET') {
      let filas = filtrar(t, params);
      const lim = u.searchParams.get('limit'); if (lim) filas = filas.slice(0, Number(lim));
      return { status: 200, body: JSON.stringify(filas) };
    }
    const body = bodyStr ? JSON.parse(bodyStr) : null;
    if (method === 'POST') {
      const entrada = Array.isArray(body) ? body : [body];
      const nuevas = [];
      for (const r0 of entrada) { const e = validarColumnas(t, r0); if (e) return e; nuevas.push(defaults(t, r0)); }
      const todas = T[t].concat(nuevas);
      for (const r of nuevas) { const e = validarFila(t, r, todas); if (e) return e; }
      T[t].push(...nuevas); base.escrituras++;
      return { status: 201, body: JSON.stringify(clon(nuevas)) };
    }
    if (method === 'PATCH') {
      const e0 = validarColumnas(t, body); if (e0) return e0;
      const objetivo = filtrar(t, params);
      const cambios = objetivo.map(r => defaults(t, Object.assign({}, r, body)));
      const resto = T[t].filter(r => !objetivo.includes(r));
      const todas = resto.concat(cambios);
      for (const r of cambios) { const e = validarFila(t, r, todas); if (e) return e; }
      objetivo.forEach((r, i) => { Object.keys(r).forEach(k => delete r[k]); Object.assign(r, cambios[i]); });
      if (objetivo.length) base.escrituras++;
      return { status: 200, body: JSON.stringify(clon(objetivo)) };
    }
    if (method === 'DELETE') {
      const objetivo = filtrar(t, params);
      T[t] = T[t].filter(r => !objetivo.includes(r)); base.T[t] = T[t];
      return { status: 200, body: JSON.stringify(clon(objetivo)) };
    }
    return error(405, 'PGRST', 'metodo');
  }
  /* fallas: {metodo, tabla, n (n-esima coincidencia, 1 = primera), modo, filtro?(url,body)}
     modos: perdida (aplica y pierde la respuesta), antes (no aplica, error de red),
            http502 (aplica y responde 502), http400 (no aplica), json_roto (aplica, cuerpo ilegible) */
  base.fetch = async function (url, opts) {
    opts = opts || {};
    const method = (opts.method || 'GET').toUpperCase();
    const tabla = (new URL(url).pathname.match(/\/rest\/v1\/([a-z_]+)/) || [])[1];
    const entrada = { method, url, tabla, body: opts.body };
    base.log.push(entrada);
    let falla = null;
    /* n = numero de la peticion coincidente (1 = primera), contado para cada falla */
    for (const f of base.fallas) {
      if (f.usada || f.metodo !== method || f.tabla !== tabla) continue;
      if (f.filtro && !f.filtro(url, opts.body)) continue;
      f.visto = (f.visto || 0) + 1;
      if (!falla && f.visto === (f.n || 1)) { falla = f; f.usada = true; }
    }
    if (falla && falla.modo === 'antes') throw new TypeError('Failed to fetch (simulado, no enviado)');
    /* tardia: el cliente cancela la espera (AbortController) y la escritura llega al
       servidor MAS TARDE, cuando la prueba llama a base.aplicarTardias(). */
    if (falla && falla.modo === 'tardia') { base.tardias.push({ method, url, body: opts.body }); throw new DOMException('The operation was aborted.', 'AbortError'); }
    if (falla && falla.modo === 'http400') return new Response(JSON.stringify({ code: 'XX000', message: 'rechazo simulado' }), { status: 400 });
    if (falla && falla.modo === 'http500_sin_aplicar') return new Response('{}', { status: 500 });
    if (falla && falla.antesDeAplicar) await falla.antesDeAplicar();
    const r = manejar(method, url, opts.body);
    entrada.status = r.status;
    if (falla && falla.modo === 'perdida') throw new TypeError('Failed to fetch (simulado, aplicado en servidor)');
    if (falla && falla.modo === 'http502') return new Response('<html>Bad gateway</html>', { status: 502 });
    if (falla && falla.modo === 'json_roto') return new Response('{"trunc', { status: r.status });
    if (falla && falla.antesDeResponder) await falla.antesDeResponder();
    return new Response(r.body, { status: r.status, headers: { 'content-type': 'application/json' } });
  };
  base.manejar = manejar;
  base.tardias = [];
  base.aplicarTardias = () => { const r = base.tardias.map(t => manejar(t.method, t.url, t.body)); base.tardias = []; return r; };
  base.escriturasDe = (tabla) => base.log.filter(x => x.method !== 'GET' && (!tabla || x.tabla === tabla) && x.status && x.status < 300).length;
  if (seed) for (const t of Object.keys(seed)) for (const r of seed[t]) T[t].push(defaults(t, r));
  return base;
}
module.exports = { crearBase, tsCanon, tsPg };
