'use strict';
/* SERVIDOR LOCAL DE ENSAYO "ocultar productos en Inventario" contra el staging ca10112ba2. Lo arranca Michel; las credenciales se escriben de forma
   interactiva y viven SOLO en la memoria de este proceso (nunca se guardan, registran ni sirven). Es un proxy autenticado: la copia local del dashboard
   (esta rama, con SB apuntando a http://127.0.0.1:<puerto>) y los guiones hablan con este proceso, que reenvia a staging con la clave anon y el JWT del
   usuario FICTICIO de staging (como la fase C del hotfix de cotizaciones). Ni el HTML ni las capturas contienen la URL, las claves ni el JWT.
   Defensas:
     - Solo acepta el proyecto con huella ca10112ba2 y rechaza produccion (las mismas funciones del servidor de ensayo del hotfix).
     - Lecturas (GET): se reenvian. Escrituras: lista blanca y SOLO sobre registros de ensayo:
         inventario            : crear productos "ens-ocu-*" con nombre "(ENSAYO OCULTAR)"; modificar solo id=eq.ens-ocu-*; (DELETE solo con --permitir-retirada)
         inventario_bodega     : crear/modificar solo filas de prod_id ens-ocu-*; (DELETE solo con --permitir-retirada)
         producto_presentaciones: crear/modificar solo id_producto ens-ocu-* (la entrada de stock con costo la escribe la aplicacion)
         bodegas               : crear UNA bodega solo si su nombre contiene "(ENSAYO)" (solo si staging aun no tiene bodega)
         rpc                   : solo lacava_mi_sesion
     - Cualquier otra escritura se bloquea con 403 ENSAYO_BLOQUEADO y queda en el registro. Nunca se tocan los productos reales ni los ensayos anteriores (ens-*).
   Controles: /__guarda, /__log. */
const http = require('node:http'), fs = require('node:fs'), path = require('node:path');
const { validarDestino, normalizarUrl, HUELLA_STAGING } = require('../../hotfix-cotizaciones/ensayo/servidor-ensayo-staging.cjs');
const RAIZ = path.join(__dirname, '..', '..', '..');
const PREFIJO = 'ens-ocu-', MARCA_NOMBRE = '(ENSAYO OCULTAR)';
const ANCLA_ID = new RegExp('(^|&)id=eq\\.' + PREFIJO + '[A-Za-z0-9_-]+(&|$)');
const ANCLA_PROD = new RegExp('(^|&)prod_id=eq\\.' + PREFIJO + '[A-Za-z0-9_-]+(&|$)');
const ANCLA_IDPROD = new RegExp('(^|&)id_producto=eq\\.' + PREFIJO + '[A-Za-z0-9_-]+(&|$)');

function filas(cuerpo) { try { return [].concat(JSON.parse(cuerpo.toString('utf8') || 'null')); } catch (e) { return null; } }
/* Devuelve null si la escritura esta permitida, o el motivo del bloqueo. */
function permitirEscritura(metodo, ruta, query, cuerpo, opciones) {
  opciones = opciones || {};
  const rp = ruta.replace(/^\/rest\/v1\//, '');
  if (/^rpc\/lacava_mi_sesion$/.test(rp)) return null;
  if (/^rpc\//.test(rp)) return 'RPC no permitida: ' + rp;
  const soloEnsayo = (b, campo) => b && b.length > 0 && b.every(f => f && String(f[campo] || '').startsWith(PREFIJO));
  if (rp === 'inventario') {
    if (metodo === 'POST') { const b = filas(cuerpo); return soloEnsayo(b, 'id') && b.every(f => String(f.nombre || '').includes(MARCA_NOMBRE)) ? null : 'solo se crean productos ' + PREFIJO + '* con nombre "' + MARCA_NOMBRE + '"'; }
    if (metodo === 'PATCH') return ANCLA_ID.test(query) ? null : 'solo se modifican productos ' + PREFIJO + '*';
    if (metodo === 'DELETE') return opciones.permitirRetirada && ANCLA_ID.test(query) ? null : 'DELETE no permitido (solo con --permitir-retirada y sobre ' + PREFIJO + '*)';
    return 'metodo no permitido en inventario';
  }
  if (rp === 'inventario_bodega') {
    if (metodo === 'POST') return soloEnsayo(filas(cuerpo), 'prod_id') ? null : 'solo se crean filas de bodega de productos ' + PREFIJO + '*';
    if (metodo === 'PATCH') return ANCLA_PROD.test(query) ? null : 'solo se modifican filas de bodega de productos ' + PREFIJO + '*';
    if (metodo === 'DELETE') return opciones.permitirRetirada && ANCLA_PROD.test(query) ? null : 'DELETE no permitido (solo con --permitir-retirada y sobre ' + PREFIJO + '*)';
    return 'metodo no permitido en inventario_bodega';
  }
  if (rp === 'producto_presentaciones') {
    if (metodo === 'POST') return soloEnsayo(filas(cuerpo), 'id_producto') ? null : 'solo presentaciones de productos ' + PREFIJO + '*';
    if (metodo === 'PATCH') return ANCLA_IDPROD.test(query) ? null : 'solo presentaciones de productos ' + PREFIJO + '*';
    if (metodo === 'DELETE') return opciones.permitirRetirada && ANCLA_IDPROD.test(query) ? null : 'DELETE no permitido (solo con --permitir-retirada y sobre ' + PREFIJO + '*)';
    return 'metodo no permitido en producto_presentaciones';
  }
  if (rp === 'bodegas') {
    if (metodo !== 'POST') return 'solo se puede CREAR la bodega de ensayo';
    const b = filas(cuerpo); return b && b.length === 1 && String(b[0].nombre || '').includes('(ENSAYO)') ? null : 'la bodega de ensayo debe llevar "(ENSAYO)" en el nombre';
  }
  return 'tabla no permitida para escritura: ' + rp;
}

function crearProxy(o) {
  const estado = { log: [], n: 0 };
  const origen = () => 'http://127.0.0.1:' + o.puerto;
  const reg = (m, r, st, extra) => { estado.n++; estado.log.push(Object.assign({ n: estado.n, metodo: m, ruta: r, estado: st }, extra || {})); if (estado.log.length > 5000) estado.log.shift(); };
  const json = (res, st, obj) => { res.writeHead(st, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
  const leer = (req) => new Promise((ok, no) => { const p = []; let t = 0; req.on('data', c => { t += c.length; if (t > 2e6) { no(new Error('cuerpo demasiado grande')); req.destroy(); } else p.push(c); }); req.on('end', () => ok(Buffer.concat(p))); req.on('error', no); });
  const dashboardHtml = () => {
    let h = fs.readFileSync(path.join(RAIZ, 'dashboard_lacava.html'), 'utf8');
    const re = /var SB='https:\/\/[a-z0-9]+\.supabase\.co';/;
    if (!re.test(h)) throw new Error('No se encontro la constante SB del dashboard');
    h = h.replace(re, () => "var SB='" + origen() + "';");
    if (/supabase\.co/.test(h.replace(/https:\/\/(?:fonts|wa)\.[a-z.]+/g, ''))) throw new Error('El dashboard conserva una URL de supabase.co');
    return h.replace('<head>', () => "<head><script>try{localStorage.setItem('lcava_session_v1',JSON.stringify({ok:true,ts:Date.now()}));}catch(e){}</script>");
  };
  const servidor = http.createServer(async (req, res) => {
    const u = new URL(req.url, origen());
    try {
      if (u.pathname === '/' || u.pathname === '/dashboard_lacava.html') { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); return res.end(dashboardHtml()); }
      if (u.pathname === '/__guarda') return json(res, 200, { proyecto: HUELLA_STAGING, ensayo: 'ocultar-inventario', sesion: o.sesion ? o.sesion() : null, escrituras_permitidas: 'solo productos ' + PREFIJO + '*', retirada: !!o.permitirRetirada });
      if (u.pathname === '/__log') return json(res, 200, estado.log);
      if (!u.pathname.startsWith('/rest/v1/')) { res.writeHead(404); return res.end(); }
      const cuerpo = req.method === 'GET' || req.method === 'HEAD' ? Buffer.alloc(0) : await leer(req);
      const ruta = u.pathname, query = u.search.replace(/^\?/, '');
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        const motivo = permitirEscritura(req.method, ruta, decodeURIComponent(query), cuerpo, { permitirRetirada: !!o.permitirRetirada });
        if (motivo) { reg(req.method, ruta, 403, { bloqueado: true, motivo }); return json(res, 403, { code: 'ENSAYO_BLOQUEADO', message: 'Bloqueado por el servidor de ensayo: ' + motivo }); }
      }
      const cab = { 'content-type': req.headers['content-type'] || 'application/json', accept: req.headers.accept || 'application/json' };
      for (const k of ['prefer', 'range', 'accept-profile', 'content-profile']) if (req.headers[k]) cab[k] = req.headers[k];
      Object.assign(cab, await o.credenciales());
      const r = await o.fetch(o.base + ruta + (query ? '?' + query : ''), { method: req.method, headers: cab, body: cuerpo.length ? cuerpo : undefined });
      const txt = Buffer.from(await r.arrayBuffer());
      reg(req.method, ruta, r.status);
      const cabRes = { 'content-type': r.headers.get('content-type') || 'application/json' };
      if (r.headers.get('content-range')) cabRes['content-range'] = r.headers.get('content-range');
      res.writeHead(r.status, cabRes); res.end(txt);
    } catch (e) { reg(req.method, req.url, 500, { error: String(e.message).slice(0, 120) }); try { json(res, 502, { code: 'ENSAYO_ERROR', message: String(e.message) }); } catch (x) { /* socket */ } }
  });
  return { servidor, estado, permitirEscritura };
}

/* ---------- uso interactivo ---------- */
function puertoElegido(porDefecto) { const i = process.argv.indexOf('--puerto'); if (i < 0) return porDefecto; const n = Number(process.argv[i + 1]); if (!Number.isInteger(n) || n < 1024 || n > 65535) { console.error('--puerto debe ser un numero entre 1024 y 65535'); process.exit(2); } return n; }
async function main() {
  const { pedir } = require('../../hotfix-cotizaciones/ensayo/entrada-oculta.cjs');
  const permitirRetirada = process.argv.includes('--permitir-retirada');
  console.log('Servidor local de ensayo OCULTAR PRODUCTOS EN INVENTARIO contra el STAGING ' + HUELLA_STAGING + (permitirRetirada ? ' (con RETIRADA de los productos ens-ocu-* habilitada)' : '') + '. Las credenciales solo viven en la memoria de este proceso.');
  const url = normalizarUrl(await pedir('URL del proyecto de STAGING (https://xxxx.supabase.co): '));
  const mal = validarDestino(url); if (mal) { console.error(mal); process.exit(4); }
  const anon = await pedir('Clave anon de STAGING (no se muestra): ', true, true);
  const email = await pedir('Correo del usuario FICTICIO de staging: ');
  const clave = await pedir('Contrasena del usuario ficticio (no se muestra): ', true);
  const frase = await pedir('Para continuar escribe exactamente  ABRIR SERVIDOR OCULTAR INVENTARIO EN STAGING : ');
  if (frase !== 'ABRIR SERVIDOR OCULTAR INVENTARIO EN STAGING') { console.error('Confirmacion distinta. No se conecto.'); process.exit(4); }
  if (anon.length < 20 || !/@/.test(email) || clave.length < 6) { console.error('Datos no validos. No se conecto.'); process.exit(2); }
  let tok = null, vence = 0, caducada = false;
  async function iniciar(cuerpo, tipo) {
    const r = await fetch(url + '/auth/v1/token?grant_type=' + tipo, { method: 'POST', headers: { apikey: anon, 'content-type': 'application/json' }, body: JSON.stringify(cuerpo) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j.access_token) throw new Error('No se pudo iniciar sesion con el usuario ficticio (HTTP ' + r.status + ')');
    tok = j; vence = Date.now() + (Number(j.expires_in) || 3600) * 1000;
  }
  await iniciar({ email, password: clave }, 'password');
  const credenciales = async () => {
    if (Date.now() > vence - 120000) {
      try { await iniciar({ refresh_token: tok.refresh_token }, 'refresh_token'); }
      catch (e) { if (!caducada) { caducada = true; console.error('\nSESION CADUCADA: detén este servidor (Ctrl+C) y vuelve a iniciarlo.'); } throw new Error('sesion caducada'); }
    }
    return { apikey: anon, Authorization: 'Bearer ' + tok.access_token };
  };
  const ms = await fetch(url + '/rest/v1/rpc/lacava_mi_sesion', { method: 'POST', headers: Object.assign({ 'content-type': 'application/json' }, await credenciales()), body: '{}' });
  const msj = await ms.json().catch(() => ({}));
  if (!ms.ok) { console.error('El usuario ficticio no tiene sesion valida de La Cava (HTTP ' + ms.status + '). No se abre el servidor.'); process.exit(3); }
  const sesion = { licencia: msj.licencia, rol: msj.rol };
  const puerto = puertoElegido(5192);
  const p = crearProxy({ puerto, base: url, fetch, credenciales, permitirRetirada, sesion: () => Object.assign({}, sesion, { caducada }) });
  await new Promise((ok, no) => { p.servidor.once('error', no); p.servidor.listen(puerto, '127.0.0.1', ok); });
  console.log('\nSesion verificada: licencia "' + sesion.licencia + '", rol ' + sesion.rol + '.');
  console.log('Servidor LISTO en http://127.0.0.1:' + puerto + '  (proyecto de staging con huella ' + HUELLA_STAGING + '). Abre esa direccion en el navegador.');
  console.log('Deja esta ventana abierta mientras duran las pruebas. Para terminar: Ctrl+C.');
  const salir = () => { const dir = path.join(process.env.USERPROFILE || '.', 'LaCava-evidencia-local', 'inventario-ocultar-staging-' + HUELLA_STAGING); try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(path.join(dir, 'registro-servidor-' + new Date().toISOString().replace(/[:.]/g, '-') + '.json'), JSON.stringify(p.estado.log, null, 1), { flag: 'wx' }); } catch (e) { /* sin registro */ } process.exit(0); };
  process.on('SIGINT', salir); process.on('SIGTERM', salir);
}
if (require.main === module) main().catch(e => { console.error('Error: ' + e.message); process.exit(3); });
module.exports = { crearProxy, permitirEscritura, PREFIJO, MARCA_NOMBRE };
