'use strict';
/* Prueba LOCAL del service worker con los ARCHIVOS REALES de deploy, en un perfil de Chrome AISLADO (carpeta temporal nueva).
   v1 = deploy/ del commit de produccion anterior al hotfix (eacde3b o LACAVA_REV_PUBLICADA; cache "lacava-v1"); v2 = deploy/ del arbol de trabajo (cache "lacava-v2").
   Un servidor local emula Netlify (la regla "/  /dashboard_lacava.html  200" de _redirects y Cache-Control: max-age=0, must-revalidate).
   Se instala v1, se "despliega" v2 y se mide: cuando se activa v2, que pasa con la cache v1 y cuantas cargas hacen falta para ver el HTML nuevo.
   SEGURIDAD: Chrome arranca con --host-resolver-rules que anula *.supabase.co (el dashboard trae la URL de produccion): ninguna
   solicitud sale hacia Supabase; ademas se registra cada host contactado y se exige que no haya ninguno de supabase.co. */
const http = require('node:http'), fs = require('node:fs'), os = require('node:os'), path = require('node:path'), cp = require('node:child_process');
const RAIZ = path.join(__dirname, '..', '..', '..');
const REV_PUBLICADA = process.env.LACAVA_REV_PUBLICADA || 'eacde3b';   /* produccion antes del hotfix (cache lacava-v1) */
const CHROME = ['C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'].find(p => fs.existsSync(p));
const ARCH = ['index.html', 'dashboard_lacava.html', 'sw.js', 'manifest.json', 'catalogo.html', 'icon-192.png', 'icon-512.png'];
const TIPOS = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.json': 'application/json', '.png': 'image/png' };
const dormir = ms => new Promise(r => setTimeout(r, ms));
const resultados = [];
const marca = (n, ok, d) => { resultados.push({ nombre: n, ok: !!ok, detalle: d || '' }); console.log((ok ? '  OK    ' : '  FALLA ') + n + (d ? ' — ' + d : '')); };

(async () => {
  if (!CHROME) { console.error('No se encontro Chrome ni Edge.'); process.exit(2); }
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lacava-sw-'));
  const dirs = { v1: path.join(tmp, 'v1'), v2: path.join(tmp, 'v2'), perfil: path.join(tmp, 'perfil') };
  fs.mkdirSync(dirs.v1); fs.mkdirSync(dirs.v2);
  for (const a of ARCH) {
    fs.writeFileSync(path.join(dirs.v1, a), cp.execFileSync('git', ['show', REV_PUBLICADA + ':deploy/' + a], { cwd: RAIZ, maxBuffer: 1 << 28 }));
    fs.copyFileSync(path.join(RAIZ, 'deploy', a), path.join(dirs.v2, a));
  }
  let actual = 'v1'; const pedidos = [];
  const servidor = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x'); let p = u.pathname; pedidos.push({ version: actual, ruta: p });
    if (p === '/') p = '/dashboard_lacava.html';              /* _redirects: "/  /dashboard_lacava.html  200" */
    const f = path.join(dirs[actual], p.replace(/^\//, ''));
    if (!f.startsWith(dirs[actual]) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end('no'); }
    res.writeHead(200, { 'content-type': TIPOS[path.extname(f)] || 'application/octet-stream', 'cache-control': 'public, max-age=0, must-revalidate' });
    res.end(fs.readFileSync(f));
  });
  await new Promise(ok => servidor.listen(0, '127.0.0.1', ok));
  const puerto = servidor.address().port, origen = 'http://127.0.0.1:' + puerto;
  const dbg = 9300 + Math.floor(Math.random() * 500);
  const chrome = cp.spawn(CHROME, ['--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync', '--user-data-dir=' + dirs.perfil,
    '--remote-debugging-port=' + dbg, '--host-resolver-rules=MAP *.supabase.co ~NOTFOUND', 'about:blank'], { stdio: 'ignore' });
  const limpiar = async () => { try { chrome.kill(); } catch (e) { /* ya cerrado */ } servidor.close(); for (let i = 0; i < 8; i++) { await dormir(500); try { fs.rmSync(tmp, { recursive: true, force: true }); if (!fs.existsSync(tmp)) break; } catch (e) { /* perfil en uso */ } } };
  try {
    let lista = null;
    for (let i = 0; i < 60 && !lista; i++) { try { lista = await (await fetch('http://127.0.0.1:' + dbg + '/json/list')).json(); if (!lista.find(t => t.type === 'page')) lista = null; } catch (e) { await dormir(250); } }
    if (!lista) throw new Error('Chrome no arranco');
    const ws = new WebSocket(lista.find(t => t.type === 'page').webSocketDebuggerUrl); await new Promise((ok, no) => { ws.onopen = ok; ws.onerror = no; });
    let id = 0; const esp = new Map(), hosts = new Set(), carga = [];
    ws.onmessage = m => { const j = JSON.parse(m.data); if (j.id && esp.has(j.id)) { esp.get(j.id)(j); esp.delete(j.id); } else if (j.method === 'Network.requestWillBeSent') { try { hosts.add(new URL(j.params.request.url).host); } catch (e) { /* data: */ } } else if (j.method === 'Page.loadEventFired') carga.push(Date.now()); };
    const cmd = (method, params) => new Promise(ok => { const i = ++id; esp.set(i, ok); ws.send(JSON.stringify({ id: i, method, params: params || {} })); });
    const ev = async expr => { const r = await cmd('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.result.exceptionDetails) return { error: r.result.exceptionDetails.text + ' ' + JSON.stringify(r.result.exceptionDetails.exception && r.result.exceptionDetails.exception.description || '') }; return r.result.result.value; };
    await cmd('Page.enable'); await cmd('Network.enable'); await cmd('Runtime.enable');
    const ir = async () => { const n = carga.length; await cmd('Page.navigate', { url: origen + '/' }); for (let i = 0; i < 80 && carga.length === n; i++) await dormir(250); await dormir(1500); };
    const recargar = async () => { const n = carga.length; await cmd('Page.reload', { ignoreCache: false }); for (let i = 0; i < 80 && carga.length === n; i++) await dormir(250); await dormir(1500); };
    const estado = () => ev(`(async()=>{ const r=await navigator.serviceWorker.getRegistration(); const k=await caches.keys(); let marcaCache={}; for (const n of k){ const c=await caches.open(n); const m=await c.match('/'); marcaCache[n]= m ? (await m.text()).includes('convertir_cotizacion_atomica') : 'sin /'; }
      return { controlado: !!navigator.serviceWorker.controller, activo: r&&r.active? r.active.scriptURL.split('/').pop():null, esperando: !!(r&&r.waiting), instalando: !!(r&&r.installing), caches:k, cacheTieneHtmlNuevo:marcaCache, htmlNuevoCargado: typeof window.llamarConversionAtomicaCot==='function', cacheDelSw: (await (await fetch('/sw.js',{cache:'no-store'})).text()).match(/CACHE = '([^']+)'/)[1] }; })()`);

    console.log('Perfil aislado: ' + dirs.perfil.replace(os.tmpdir(), '<tmp>') + ' (nuevo y temporal)');
    console.log('\nA) Produccion actual (v1): primera visita y recarga');
    await ir(); await recargar();
    let e1 = await estado();
    marca('v1 instalado y activo, cache lacava-v1, pagina controlada', e1.activo === 'sw.js' && e1.cacheDelSw === 'lacava-v1' && JSON.stringify(e1.caches) === '["lacava-v1"]' && e1.controlado, JSON.stringify(e1));
    marca('v1 NO tiene el HTML nuevo (sin conversion atomica)', e1.htmlNuevoCargado === false && e1.cacheTieneHtmlNuevo['lacava-v1'] === false, 'htmlNuevoCargado=' + e1.htmlNuevoCargado);

    console.log('\nB) Se despliega v2 (sw lacava-v2 + HTML nuevo) y el usuario vuelve a abrir la app');
    actual = 'v2'; const antesPedidos = pedidos.length;
    await ir();                                   /* primera carga tras el despliegue */
    await dormir(2500);
    const tras1 = await estado();
    marca('Tras la 1.a carga: el navegador detecto sw.js nuevo y activo v2 (cache v1 borrada)', tras1.cacheDelSw === 'lacava-v2' && JSON.stringify(tras1.caches) === '["lacava-v2"]', JSON.stringify(tras1));
    marca('v2 guardo el HTML nuevo en su cache al instalarse', tras1.cacheTieneHtmlNuevo['lacava-v2'] === true);
    console.log('     (informativo) HTML nuevo mostrado en la 1.a carga tras desplegar: ' + tras1.htmlNuevoCargado);
    let cargas = 1, e = tras1;
    while (!e.htmlNuevoCargado && cargas < 4) { await recargar(); cargas++; e = await estado(); }
    marca('El HTML nuevo termina cargandose (cargas necesarias tras desplegar: ' + cargas + ')', e.htmlNuevoCargado === true && cargas <= 2, 'activo ' + e.activo + ', controlado ' + e.controlado);
    marca('Estado final: un solo service worker activo (v2), cache unica lacava-v2, sin sw en espera', e.activo === 'sw.js' && e.cacheDelSw === 'lacava-v2' && JSON.stringify(e.caches) === '["lacava-v2"]' && !e.esperando && !e.instalando, JSON.stringify(e));
    marca('sw.js se pidio a la red tras el despliegue (el navegador comprueba actualizaciones)', pedidos.slice(antesPedidos).some(p => p.ruta === '/sw.js'));

    console.log('\nC) Seguridad de la prueba');
    const malos = [...hosts].filter(h => /supabase\.co/.test(h));
    marca('Ninguna solicitud salio hacia supabase.co (resolucion anulada)', malos.length === 0, 'hosts contactados: ' + [...hosts].join(', '));
    ws.close(); await limpiar();
    const fin = resultados.filter(r => !r.ok).length;
    console.log('\nResumen: ' + (resultados.length - fin) + ' de ' + resultados.length + ' comprobaciones correctas' + (fin ? ', ' + fin + ' FALLARON.' : '.'));
    const dir = path.join(os.homedir(), 'LaCava-evidencia-local', 'hotfix-staging-ca10112ba2'); fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'resultado-service-worker-' + new Date().toISOString().replace(/[:.]/g, '-') + '.json'), JSON.stringify({ fecha: new Date().toISOString(), cargas_para_html_nuevo: cargas, resultados }, null, 1));
    process.exit(fin ? 1 : 0);
  } catch (e) { console.error('DETENIDO: ' + e.message); await limpiar(); process.exit(3); }
})();
