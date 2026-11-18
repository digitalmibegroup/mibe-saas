'use strict';
/* SERVIDOR LOCAL DE ENSAYO contra el staging ca10112ba2 (fases C y D). Lo arranca Michel; las credenciales se escriben
   de forma interactiva y viven SOLO en la memoria de este proceso: nunca se guardan, se registran ni se sirven.
   Funciona como un proxy autenticado: el navegador (copia local del dashboard) y los guiones hablan con
   http://127.0.0.1:<puerto> y este proceso reenvia a staging con la clave anon y el JWT del usuario ficticio.
   Asi ni el HTML, ni las capturas, ni el informe contienen la URL, las claves ni el JWT.
   Defensas:
     - Solo acepta el proyecto cuya huella (SHA-256 del ref, 10 primeros caracteres) es ca10112ba2 y rechaza produccion.
     - Lecturas (GET): se reenvian. Escrituras: SOLO las de las pruebas (lista blanca) y SOLO sobre registros de ensayo:
         inventario: ids que empiezan por ens-; clientes_frecuentes y cotizaciones: crear, y modificar solo los creados por
         este proceso; RPC de conversion: solo sobre cotizaciones creadas por este proceso. Nada de DELETE.
     - Cualquier otra escritura se bloquea con 403 ENSAYO_BLOQUEADO y queda en el registro.
   Controles para las pruebas: /__guarda, /__log, /__falla?modo=antes|perdida&n=N, /__creados. */
const http = require('node:http'), crypto = require('node:crypto'), fs = require('node:fs'), path = require('node:path');
const HUELLA_STAGING = 'ca10112ba2';
const HUELLA_PRODUCCION = 'cea2aa59bdf95443fef9d9a4b42bab3fd5a77bbb1131ac24b7ddc790eface400';
const sha = t => crypto.createHash('sha256').update(t).digest('hex');
const RAIZ = path.join(__dirname, '..', '..', '..');
const TABLAS_CREAR = ['clientes_frecuentes', 'cotizaciones'];
const RPC_PERMITIDAS = ['convertir_cotizacion_atomica', 'cotizacion_conversion_info', 'lacava_mi_sesion'];
const DECOY = '00000000-0000-4000-8000-000000000000';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/* Si se pega una URL con ruta (p. ej. .../rest/v1/), se queda solo con el origen. */
function normalizarUrl(t) { try { return new URL(String(t).trim()).origin; } catch (e) { return String(t || '').trim().replace(/\/+$/, ''); } }
function validarDestino(url) {
  const m = String(url || '').match(/^https:\/\/([a-z0-9]{20})\.supabase\.co\/?$/);
  if (!m) return 'La URL debe ser https://<ref de 20 caracteres>.supabase.co';
  if (sha(m[1]) === HUELLA_PRODUCCION) return 'Ese es el proyecto de PRODUCCION. No se conecto.';
  if (sha(m[1]).slice(0, 10) !== HUELLA_STAGING) return 'Ese proyecto NO es el staging esperado (huella ' + sha(m[1]).slice(0, 10) + '). No se conecto.';
  return null;
}

/* Nucleo del proxy (sin credenciales propias: recibe la funcion que las inyecta). Se prueba en local con un upstream falso. */
function crearProxy(o) {
  const estado = { log: [], creados: { cotizaciones: new Set(), clientes_frecuentes: new Set() }, fallas: [], n: 0 };
  const origen = () => 'http://127.0.0.1:' + o.puerto;
  const dashboardHtml = () => {
    let h = fs.readFileSync(path.join(RAIZ, 'dashboard_lacava.html'), 'utf8');
    const re = /var SB='https:\/\/[a-z0-9]+\.supabase\.co';/;
    if (!re.test(h)) throw new Error('No se encontro la constante SB del dashboard');
    h = h.replace(re, () => "var SB='" + origen() + "';");
    if (/supabase\.co/.test(h.replace(/https:\/\/(?:fonts|wa)\.[a-z.]+/g, ''))) throw new Error('El dashboard conserva una URL de supabase.co');
    return h.replace('<head>', () => "<head><script>try{localStorage.setItem('lcava_session_v1',JSON.stringify({ok:true,ts:Date.now()}));}catch(e){}</script>");
  };
  const reg = (m, r, st, extra) => { estado.n++; estado.log.push(Object.assign({ n: estado.n, metodo: m, ruta: r, estado: st }, extra || {})); if (estado.log.length > 5000) estado.log.shift(); };
  const json = (res, st, obj) => { res.writeHead(st, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
  const leer = (req) => new Promise((ok, no) => { const p = []; let t = 0; req.on('data', c => { t += c.length; if (t > 2e6) { no(new Error('cuerpo demasiado grande')); req.destroy(); } else p.push(c); }); req.on('end', () => ok(Buffer.concat(p))); req.on('error', no); });

  /* Devuelve null si la escritura esta permitida, o el motivo del bloqueo. */
  function permitirEscritura(metodo, ruta, query, cuerpo, sinSesion) {
    const rp = ruta.replace(/^\/rest\/v1\//, '');
    if (rp === 'cotizacion_conversiones') return null; /* prueba NEGATIVA: la base debe rechazarlo (anon y authenticated sin privilegios) */
    const rpc = rp.match(/^rpc\/([a-z_]+)$/);
    if (rpc) {
      if (!RPC_PERMITIDAS.includes(rpc[1])) return 'RPC no permitida: ' + rpc[1];
      if (rpc[1] === 'convertir_cotizacion_atomica') {
        let b = {}; try { b = JSON.parse(cuerpo.toString('utf8') || '{}'); } catch (e) { return 'cuerpo no valido'; }
        if (sinSesion) return String(b.p_cotizacion_id || '') === DECOY ? null : 'sin sesion solo se permite la cotizacion senuelo'; /* prueba NEGATIVA de anon: la base debe rechazarla por permisos */
        if (!estado.creados.cotizaciones.has(String(b.p_cotizacion_id || '').toLowerCase())) return 'la cotizacion no fue creada por este ensayo';
      }
      return null;
    }
    if (rp === 'inventario') {
      if (metodo === 'POST') { let b; try { b = [].concat(JSON.parse(cuerpo.toString('utf8'))); } catch (e) { return 'cuerpo no valido'; } return b.every(f => /^ens-/.test(String(f.id || ''))) ? null : 'solo productos ens-* de ensayo'; }
      if (metodo === 'PATCH') return /(^|&)id=eq\.ens-/.test(query) ? null : 'solo se modifican productos ens-*';
      return 'metodo no permitido en inventario';
    }
    if (TABLAS_CREAR.includes(rp)) {
      if (metodo === 'POST') return null;
      if (metodo === 'PATCH') { const m = query.match(/(?:^|&)id=eq\.([0-9a-f-]{36})(?:&|$)/i); return (m && estado.creados[rp].has(m[1].toLowerCase())) ? null : 'solo se modifican registros creados por este ensayo'; }
      return 'metodo no permitido';
    }
    return 'tabla no permitida para escritura: ' + rp;
  }

  const servidor = http.createServer(async (req, res) => {
    const u = new URL(req.url, origen());
    try {
      if (u.pathname === '/' || u.pathname === '/dashboard_lacava.html') { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); return res.end(dashboardHtml()); }
      if (u.pathname === '/__guarda') return json(res, 200, { proyecto: HUELLA_STAGING, sesion: o.sesion ? o.sesion() : null, escrituras_permitidas: 'solo registros de ensayo', creados: { cotizaciones: estado.creados.cotizaciones.size, clientes_frecuentes: estado.creados.clientes_frecuentes.size } });
      if (u.pathname === '/__log') return json(res, 200, estado.log);
      if (u.pathname === '/__creados') return json(res, 200, { cotizaciones: [...estado.creados.cotizaciones], clientes_frecuentes: [...estado.creados.clientes_frecuentes] });
      if (u.pathname === '/__falla') { const modo = u.searchParams.get('modo'), n = Number(u.searchParams.get('n') || 1); if (!['antes', 'perdida', 'limpiar'].includes(modo)) return json(res, 400, { error: 'modo' }); if (modo === 'limpiar') estado.fallas = []; else estado.fallas.push({ modo, n }); return json(res, 200, { fallas: estado.fallas }); }
      if (!u.pathname.startsWith('/rest/v1/')) { res.writeHead(404); return res.end(); }
      const cuerpo = req.method === 'GET' || req.method === 'HEAD' ? Buffer.alloc(0) : await leer(req);
      const sinSesion = req.headers['x-ensayo-sin-sesion'] === '1';
      const ruta = u.pathname, query = u.search.replace(/^\?/, '');
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        const motivo = permitirEscritura(req.method, ruta, decodeURIComponent(query), cuerpo, sinSesion);
        if (motivo) { reg(req.method, ruta, 403, { bloqueado: true, motivo }); return json(res, 403, { code: 'ENSAYO_BLOQUEADO', message: 'Bloqueado por el servidor de ensayo: ' + motivo }); }
      }
      /* fallas simuladas de red sobre la RPC de conversion */
      const esConv = req.method === 'POST' && /\/rpc\/convertir_cotizacion_atomica$/.test(ruta);
      let falla = null; if (esConv && estado.fallas.length) { falla = estado.fallas[0]; if (--falla.n <= 0) estado.fallas.shift(); }
      if (falla && falla.modo === 'antes') { reg(req.method, ruta, 0, { simulado: 'solicitud perdida antes de enviarse' }); return req.socket.destroy(); }
      const cab = { 'content-type': req.headers['content-type'] || 'application/json', accept: req.headers.accept || 'application/json' };
      for (const k of ['prefer', 'range', 'accept-profile', 'content-profile']) if (req.headers[k]) cab[k] = req.headers[k];
      const cred = await o.credenciales(sinSesion);
      Object.assign(cab, cred);
      const r = await o.fetch(o.base + ruta + (query ? '?' + query : ''), { method: req.method, headers: cab, body: cuerpo.length ? cuerpo : undefined });
      const txt = Buffer.from(await r.arrayBuffer());
      if (req.method === 'POST' && r.status < 300 && TABLAS_CREAR.includes(ruta.replace('/rest/v1/', ''))) {
        try { for (const f of [].concat(JSON.parse(txt.toString('utf8')))) if (f && f.id) estado.creados[ruta.replace('/rest/v1/', '')].add(String(f.id).toLowerCase()); } catch (e) { /* sin cuerpo */ }
      }
      reg(req.method, ruta, r.status, falla ? { simulado: 'respuesta perdida despues de aplicarse' } : (sinSesion ? { sin_sesion: true } : {}));
      if (falla && falla.modo === 'perdida') return req.socket.destroy();
      const cabRes = { 'content-type': r.headers.get('content-type') || 'application/json' };
      if (r.headers.get('content-range')) cabRes['content-range'] = r.headers.get('content-range');
      res.writeHead(r.status, cabRes); res.end(txt);
    } catch (e) { reg(req.method, req.url, 500, { error: String(e.message).slice(0, 120) }); try { json(res, 502, { code: 'ENSAYO_ERROR', message: String(e.message) }); } catch (x) { /* socket */ } }
  });
  return { servidor, estado, permitirEscritura };
}

/* ---------- uso interactivo ---------- */
function puertoElegido(porDefecto) { const i = process.argv.indexOf('--puerto'); if (i < 0) return porDefecto; const n = Number(process.argv[i + 1]); if (!Number.isInteger(n) || n < 1024 || n > 65535) { console.error('--puerto debe ser un numero entre 1024 y 65535.'); process.exit(2); } return n; }
const { pedir } = require('./entrada-oculta.cjs');
async function mainSoloAnon() {
  /* Modo SOLO ANON (fase temporal de acceso anonimo): sin usuario, sin JWT, sin envoltorio de sesion. El dashboard y los guiones
     hablan como en produccion: solo con la clave anon publica. Las demas defensas (huella, lista blanca de escrituras) siguen. */
  console.log('Servidor local de ensayo en modo SOLO ANON contra el STAGING ca10112ba2 (sin sesion autenticada). Las credenciales solo viven en la memoria de este proceso.');
  const url = normalizarUrl(await pedir('URL del proyecto de STAGING (https://xxxx.supabase.co; si pegas una ruta como /rest/v1/ se recorta sola): '));
  const mal = validarDestino(url); if (mal) { console.error(mal); process.exit(4); }
  const anon = await pedir('Clave anon (publica) de STAGING (no se muestra): ', true, true);
  const frase = await pedir('Para continuar escribe exactamente  ABRIR SERVIDOR ANON DE ENSAYO EN STAGING : ');
  if (frase !== 'ABRIR SERVIDOR ANON DE ENSAYO EN STAGING') { console.error('Confirmacion distinta. No se conecto.'); process.exit(4); }
  if (anon.length < 20) { console.error('La clave anon no es valida. No se conecto.'); process.exit(2); }
  const credenciales = async () => ({ apikey: anon, Authorization: 'Bearer ' + anon });
  const puerto = puertoElegido(5191);
  const p = crearProxy({ puerto, base: url, fetch, credenciales, sesion: () => ({ modo: 'solo anon (sin sesion)' }) });
  await new Promise((ok, no) => { p.servidor.once('error', no); p.servidor.listen(puerto, '127.0.0.1', ok); });
  console.log('\nServidor SOLO ANON LISTO en http://127.0.0.1:' + puerto + '  (proyecto de staging con huella ' + HUELLA_STAGING + ').');
  console.log('Deja esta ventana abierta mientras duran las pruebas. Para terminar: Ctrl+C.');
  const salir = () => { const dir = path.join(process.env.USERPROFILE || '.', 'LaCava-evidencia-local', 'hotfix-staging-' + HUELLA_STAGING); try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(path.join(dir, 'registro-servidor-anon-' + puerto + '-' + new Date().toISOString().replace(/[:.]/g, '-') + '.json'), JSON.stringify(p.estado.log, null, 1)); } catch (e) { /* sin carpeta */ } process.exit(0); };
  process.on('SIGINT', salir); process.on('SIGTERM', salir);
}
async function main() {
  if (process.argv.includes('--solo-anon')) return mainSoloAnon();
  console.log('Servidor local de ensayo contra el STAGING ca10112ba2 (fases C y D). Las credenciales solo viven en la memoria de este proceso.');
  const url = normalizarUrl(await pedir('URL del proyecto de STAGING (https://xxxx.supabase.co; si pegas una ruta como /rest/v1/ se recorta sola): '));
  const mal = validarDestino(url); if (mal) { console.error(mal); process.exit(4); }
  const anon = await pedir('Clave anon de STAGING (no se muestra): ', true, true);
  const email = await pedir('Correo del usuario FICTICIO de staging: ');
  const clave = await pedir('Contrasena del usuario ficticio (no se muestra): ', true);
  const frase = await pedir('Para continuar escribe exactamente  ABRIR SERVIDOR DE ENSAYO EN STAGING : ');
  if (frase !== 'ABRIR SERVIDOR DE ENSAYO EN STAGING') { console.error('Confirmacion distinta. No se conecto.'); process.exit(4); }
  if (anon.length < 20 || !/@/.test(email) || clave.length < 6) { console.error('Datos no validos. No se conecto.'); process.exit(2); }
  let tok = null, vence = 0, sesion = null, caducada = false;
  async function iniciar(cuerpo, tipo) {
    const r = await fetch(url + '/auth/v1/token?grant_type=' + tipo, { method: 'POST', headers: { apikey: anon, 'content-type': 'application/json' }, body: JSON.stringify(cuerpo) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j.access_token) throw new Error('No se pudo iniciar sesion con el usuario ficticio (HTTP ' + r.status + ')');
    tok = j; vence = Date.now() + (Number(j.expires_in) || 3600) * 1000;
  }
  await iniciar({ email, password: clave }, 'password');
  const credenciales = async (sinSesion) => {
    if (sinSesion) return { apikey: anon, Authorization: 'Bearer ' + anon };
    if (Date.now() > vence - 120000) {
      try { await iniciar({ refresh_token: tok.refresh_token }, 'refresh_token'); }
      catch (e) { if (!caducada) { caducada = true; console.error('\nSESION AUTENTICADA CADUCADA: no se pudo renovar. Detén este servidor (Ctrl+C) y vuelve a iniciarlo para iniciar sesión de nuevo con la contraseña del usuario ficticio.'); } throw new Error('SESION CADUCADA: reinicia el servidor e inicia sesion de nuevo'); }
    }
    return { apikey: anon, Authorization: 'Bearer ' + tok.access_token };
  };
  const ms = await fetch(url + '/rest/v1/rpc/lacava_mi_sesion', { method: 'POST', headers: Object.assign({ 'content-type': 'application/json' }, await credenciales(false)), body: '{}' });
  const msj = await ms.json().catch(() => ({}));
  if (!ms.ok) { console.error('El usuario ficticio no tiene sesion valida de La Cava (HTTP ' + ms.status + ': ' + (msj.message || '') + '). No se abre el servidor.'); process.exit(3); }
  sesion = { licencia: msj.licencia, rol: msj.rol, ventas_habilitadas: msj.ventas_habilitadas };
  let puerto = puertoElegido(5190);
  const p = crearProxy({ puerto, base: url, fetch, credenciales, sesion: () => Object.assign({}, sesion, { caducada }) });
  await new Promise((ok, no) => { p.servidor.once('error', no); p.servidor.listen(puerto, '127.0.0.1', ok); });
  console.log('\nSesion verificada: licencia "' + sesion.licencia + '", rol ' + sesion.rol + ', ventas habilitadas: ' + sesion.ventas_habilitadas);
  console.log('Servidor LISTO en http://127.0.0.1:' + puerto + '  (proyecto de staging con huella ' + HUELLA_STAGING + ').');
  console.log('Deja esta ventana abierta mientras duran las pruebas. Para terminar: Ctrl+C.');
  const salir = () => { const dir = path.join(process.env.USERPROFILE || '.', 'LaCava-evidencia-local', 'hotfix-staging-' + HUELLA_STAGING); try { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(path.join(dir, 'registro-servidor-ensayo-' + new Date().toISOString().replace(/[:.]/g, '-') + '.json'), JSON.stringify(p.estado.log, null, 1)); } catch (e) { /* sin carpeta */ } process.exit(0); };
  process.on('SIGINT', salir); process.on('SIGTERM', salir);
}
if (require.main === module) main().catch(e => { console.error('Error: ' + e.message); process.exit(3); });
module.exports = { crearProxy, validarDestino, normalizarUrl, HUELLA_STAGING, DECOY };
