'use strict';
/* Adaptador con forma de PostgREST sobre el PostgreSQL TEMPORAL: GET/POST/PATCH/DELETE con
   filtros simples (eq, neq, is, in, ilike, gt, gte, lt, lte, not.*), Prefer return=representation
   y llamadas RPC, TODO ejecutado como rol anon (igual que la clave anon del dashboard).
   Sirve para las pruebas locales y para ensayar el guion del ensayo. NO es PostgREST real:
   el ensayo en un proyecto separado confirma los codigos HTTP reales. Solo datos ficticios. */
const { lit } = require('./pg-temporal.cjs');

function ident(n) { if (!/^[a-z_][a-z0-9_]*$/.test(n)) throw new Error('identificador no permitido: ' + n); return '"' + n + '"'; }
function condicion(col, expr) {
  const c = ident(col);
  let negar = false, e = expr;
  if (e.startsWith('not.')) { negar = true; e = e.slice(4); }
  const i = e.indexOf('.'), op = e.slice(0, i), val = e.slice(i + 1);
  let s;
  if (op === 'eq') s = `${c} = ${lit(val)}`;
  else if (op === 'neq') s = `${c} <> ${lit(val)}`;
  else if (op === 'is') s = val === 'null' ? `${c} IS NULL` : `${c} IS ${val === 'true' ? 'TRUE' : 'FALSE'}`;
  else if (op === 'in') s = `${c} IN (${val.replace(/^\(/, '').replace(/\)$/, '').split(',').map(x => lit(x.replace(/^"|"$/g, ''))).join(',')})`;
  else if (op === 'ilike') s = `${c}::text ILIKE ${lit(val.replace(/\*/g, '%'))}`;
  else if (op === 'gt') s = `${c} > ${lit(val)}`; else if (op === 'gte') s = `${c} >= ${lit(val)}`;
  else if (op === 'lt') s = `${c} < ${lit(val)}`; else if (op === 'lte') s = `${c} <= ${lit(val)}`;
  else throw new Error('operador no simulado ' + op);
  return negar ? `NOT (${s})` : s;
}
const RES = new Set(['select', 'order', 'limit', 'offset', 'on_conflict']);
function donde(u) {
  const w = []; for (const [k, v] of u.searchParams.entries()) if (!RES.has(k)) w.push(condicion(k, v));
  return w.length ? ' WHERE ' + w.join(' AND ') : '';
}
function orden(u) {
  const o = u.searchParams.get('order'); if (!o) return '';
  return ' ORDER BY ' + o.split(',').map(p => { const [c, d] = p.split('.'); return ident(c) + (d === 'desc' ? ' DESC' : ''); }).join(', ');
}
function httpDe(r) {
  if (r.codigo === '42501') return 403;
  if (r.codigo === '42883') return 404;
  if (r.codigo && /^23(503|505)$/.test(r.codigo)) return 409;
  if (r.codigo === '42703' || r.codigo === '42P01') return 400;
  return 400;
}
function respuestaError(r) {
  const cod = r.codigo === '42883' ? 'PGRST202' : r.codigo;
  return new Response(JSON.stringify({ code: cod, details: null, hint: null, message: r.mensaje || r.err }), { status: httpDe(r), headers: { 'content-type': 'application/json' } });
}

function crearFetch(pg, opciones) {
  const o = Object.assign({ perderRespuestas: 0 }, opciones);
  const log = [];
  const f = async function (url, opts) {
    opts = opts || {};
    const u = new URL(url), method = (opts.method || 'GET').toUpperCase();
    log.push({ method, path: u.pathname });
    const ruta = u.pathname.replace(/^\/rest\/v1\//, '');
    const rpc = ruta.match(/^rpc\/([a-z_]+)$/);
    const pideRepr = /return=representation/.test((opts.headers && (opts.headers.Prefer || opts.headers.prefer)) || '');
    let sql, sqlCuenta = null;
    if (rpc && method === 'POST') {
      const b = JSON.parse(opts.body || '{}');
      const args = Object.keys(b).map(k => `${ident(k)} := ${b[k] == null ? 'NULL' : lit(typeof b[k] === 'object' ? JSON.stringify(b[k]) : String(b[k]))}`).join(', ');
      sql = `SELECT to_json(public.${rpc[1]}(${args}));`;
    } else if (/^[a-z_]+$/.test(ruta)) {
      const t = 'public.' + ident(ruta);
      if (method === 'GET') {
        const lim = u.searchParams.get('limit');
        sql = `SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM (SELECT * FROM ${t}${donde(u)}${orden(u)}${lim ? ' LIMIT ' + Number(lim) : ''}) x;`;
        if (/count=exact/.test((opts.headers && (opts.headers.Prefer || opts.headers.prefer)) || '')) sqlCuenta = `SELECT count(*) FROM ${t}${donde(u)};`;
      } else if (method === 'POST') {
        const filas = [].concat(JSON.parse(opts.body)); const cols = [...new Set(filas.flatMap(r => Object.keys(r)))];
        const lista = cols.map(ident).join(',');
        const merge = /resolution=merge-duplicates/.test((opts.headers && (opts.headers.Prefer || opts.headers.prefer)) || '');
        sql = `WITH ins AS (INSERT INTO ${t} (${lista}) SELECT ${lista} FROM json_populate_recordset(null::${t}, ${lit(JSON.stringify(filas))}::json)`
          + (merge ? ` ON CONFLICT (${ident(u.searchParams.get('on_conflict') || 'id')}) DO UPDATE SET ${cols.map(c => `${ident(c)} = EXCLUDED.${ident(c)}`).join(',')}` : '')
          + ` RETURNING *) SELECT COALESCE(jsonb_agg(ins), '[]'::jsonb) FROM ins;`;
      } else if (method === 'PATCH') {
        const cambios = JSON.parse(opts.body); const cols = Object.keys(cambios);
        const rec = `(json_populate_record(null::${t}, ${lit(JSON.stringify(cambios))}::json))`;
        sql = `WITH upd AS (UPDATE ${t} SET ${cols.map(c => `${ident(c)} = ${rec}.${ident(c)}`).join(',')}${donde(u)} RETURNING ${t}.*) SELECT COALESCE(jsonb_agg(upd), '[]'::jsonb) FROM upd;`;
      } else if (method === 'DELETE') {
        sql = `WITH del AS (DELETE FROM ${t}${donde(u)} RETURNING *) SELECT COALESCE(jsonb_agg(del), '[]'::jsonb) FROM del;`;
      }
    }
    if (!sql) return new Response('{"message":"no simulado"}', { status: 501 });
    const r = await pg.sqlAsync(sql, { rol: opts.rol || 'anon' });
    if (o.perderRespuestas > 0 && (rpc || method !== 'GET')) { o.perderRespuestas--; throw new TypeError('Failed to fetch (simulado: aplicado o no en la base, respuesta perdida)'); }
    if (!r.ok) return respuestaError(r);
    const cuerpo = r.out.split('\n').pop();
    if (rpc) return new Response(cuerpo, { status: 200, headers: { 'content-type': 'application/json' } });
    if (method === 'GET') {
      const cab = { 'content-type': 'application/json' };
      if (sqlCuenta) { const c = await pg.sqlAsync(sqlCuenta, { rol: opts.rol || 'anon' }); if (c.ok) cab['content-range'] = '0-0/' + c.out.split('\n').pop().trim(); }
      return new Response(cuerpo, { status: 200, headers: cab });
    }
    return pideRepr ? new Response(cuerpo, { status: method === 'POST' ? 201 : 200, headers: { 'content-type': 'application/json' } }) : new Response(null, { status: method === 'POST' ? 201 : 204 });
  };
  f.log = log; f.opciones = o;
  return f;
}
module.exports = { crearFetch };
