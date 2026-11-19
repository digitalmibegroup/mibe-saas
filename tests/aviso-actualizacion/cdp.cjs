'use strict';
/* Cliente minimo del protocolo de Chrome (CDP) para las pruebas del aviso de actualizacion. Sin dependencias.
   - Lanza Chrome/Edge sin cabeza con un perfil temporal y SIN resolucion DNS externa: solo localhost. Nada sale a internet.
   - Cada prueba usa un contexto de navegador propio (almacenamiento y service workers limpios).
   - Las llamadas a Supabase se responden con simulaciones locales; cualquier otro host externo se bloquea. */
const { spawn } = require('node:child_process');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const sleep = ms => new Promise(r => setTimeout(r, ms));

const EJECUTABLES = [
  process.env.LACAVA_NAVEGADOR,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe'
].filter(Boolean);
const buscar = () => EJECUTABLES.find(p => fs.existsSync(p));

class Conexion {
  constructor(url) { this.id = 0; this.pend = new Map(); this.oyentes = []; this.ws = new WebSocket(url); }
  abrir() {
    return new Promise((ok, no) => {
      this.ws.onopen = ok; this.ws.onerror = no;
      this.ws.onmessage = ev => {
        const m = JSON.parse(ev.data);
        if (m.id) { const p = this.pend.get(m.id); if (!p) return; this.pend.delete(m.id); m.error ? p.no(new Error(p.metodo + ': ' + m.error.message)) : p.ok(m.result); }
        else this.oyentes.slice().forEach(f => f(m));
      };
    });
  }
  enviar(metodo, params, sesion) {
    const id = ++this.id, msg = { id, method: metodo, params: params || {} };
    if (sesion) msg.sessionId = sesion;
    return new Promise((ok, no) => { this.pend.set(id, { ok, no, metodo }); this.ws.send(JSON.stringify(msg)); });
  }
  on(f) { this.oyentes.push(f); return () => { this.oyentes = this.oyentes.filter(x => x !== f); }; }
}

async function lanzar() {
  const exe = buscar();
  if (!exe) throw new Error('no se encontro Chrome ni Edge (defina LACAVA_NAVEGADOR)');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lc-nav-'));
  const proc = spawn(exe, ['--headless=new', '--remote-debugging-port=0', '--user-data-dir=' + dir, '--no-first-run', '--no-default-browser-check',
    '--disable-extensions', '--disable-gpu', '--disable-background-networking', '--disable-sync', '--mute-audio',
    '--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE localhost , EXCLUDE 127.0.0.1', 'about:blank'], { stdio: 'ignore' });
  let linea = null;
  for (let i = 0; i < 150 && !linea; i++) { try { linea = fs.readFileSync(path.join(dir, 'DevToolsActivePort'), 'utf8').split('\n'); } catch { await sleep(100); } }
  if (!linea) { proc.kill(); throw new Error('Chrome no abrio el puerto de depuracion'); }
  const con = new Conexion('ws://127.0.0.1:' + linea[0] + linea[1]);
  await con.abrir();
  return {
    con,
    async contexto() { const r = await con.enviar('Target.createBrowserContext', { disposeOnDetach: false }); return r.browserContextId; },
    async cerrarContexto(id) { try { await con.enviar('Target.disposeBrowserContext', { browserContextId: id }); } catch { } },
    async pagina(ctx, opciones) { const p = new Pagina(con, ctx, opciones || {}); await p.abrir(); return p; },
    async cerrar() { try { await con.enviar('Browser.close'); } catch { } try { con.ws.close(); } catch { } proc.kill(); await sleep(300); try { fs.rmSync(dir, { recursive: true, force: true }); } catch { } }
  };
}

const CORS = [['access-control-allow-origin', '*'], ['access-control-allow-headers', '*'], ['access-control-allow-methods', '*'], ['access-control-expose-headers', '*']];
const LICENCIA = [{ id_cliente: 'lacava', activo: true, plan: 'Prueba local', vence: null }];

class Pagina {
  constructor(con, ctx, op) {
    this.con = con; this.ctx = ctx; this.op = op; this.navegaciones = 0; this.externas = []; this.supabase = []; this.retener = null; this.fallar = false; this.datos = {}; this.manejador = null; this.consola = [];
  }
  async abrir() {
    const t = await this.con.enviar('Target.createTarget', { url: 'about:blank', browserContextId: this.ctx });
    this.targetId = t.targetId;
    this.sid = (await this.con.enviar('Target.attachToTarget', { targetId: t.targetId, flatten: true })).sessionId;
    this.off = this.con.on(m => this._evento(m));
    for (const d of ['Page', 'Runtime', 'Network']) await this.cmd(d + '.enable');
    await this.cmd('Fetch.enable', { patterns: [{ urlPattern: '*' }] });
    /* Sesion iniciada (la clave es la que usa la aplicacion) para ver la aplicacion y no la pantalla de acceso */
    await this.cmd('Page.addScriptToEvaluateOnNewDocument', { source: "try{if(!localStorage.getItem('lcava_session_v1'))localStorage.setItem('lcava_session_v1',JSON.stringify({ok:true,ts:Date.now()}));}catch(e){}" });
    /* Los avisos de caja de la propia aplicacion (apertura y recordatorio) tapan la pantalla y no forman parte de lo que se prueba */
    await this.cmd('Page.addScriptToEvaluateOnNewDocument', { source: "document.addEventListener('DOMContentLoaded',function(){var s=document.createElement('style');s.textContent='#modalCajaOverlay,#modalRecordatorioCaja{display:none!important}';document.head.appendChild(s);});" });
    await this.emular(this.op.movil ? 'movil' : 'escritorio');
  }
  cmd(m, p) { return this.con.enviar(m, p, this.sid); }
  _evento(m) {
    if (m.sessionId !== this.sid) return;
    if (m.method === 'Page.frameNavigated' && !m.params.frame.parentId) this.navegaciones++;
    if (m.method === 'Runtime.consoleAPICalled') this.consola.push(m.params.type + ': ' + m.params.args.map(a => a.value !== undefined ? a.value : a.description).join(' '));
    if (m.method === 'Fetch.requestPaused') this._pausada(m.params).catch(() => { });
  }
  async _pausada(p) {
    const u = new URL(p.request.url), id = p.requestId;
    if (u.hostname === 'localhost' || u.hostname === '127.0.0.1') return this.cmd('Fetch.continueRequest', { requestId: id });
    const responder = (codigo, cuerpo, tipo) => this.cmd('Fetch.fulfillRequest', { requestId: id, responseCode: codigo,
      responseHeaders: CORS.concat([['content-type', tipo || 'application/json']]).map(([name, value]) => ({ name, value })), body: Buffer.from(cuerpo || '').toString('base64') });
    if (u.hostname.endsWith('.supabase.co')) {
      const metodo = p.request.method;
      this.supabase.push(metodo + ' ' + u.pathname);
      if (metodo === 'OPTIONS') return responder(204, '');
      if (this.manejador) { const r = this.manejador(metodo, u, p.request.postData); if (r) return responder(r.codigo, JSON.stringify(r.cuerpo)); }   /* base simulada con estado (la define la prueba) */
      if (metodo !== 'GET' && this.retener) await this.retener;          /* guardado "en curso": la respuesta se retiene hasta liberarla */
      if (metodo !== 'GET' && this.fallar) return responder(500, '{"message":"error simulado"}');   /* guardado que falla */
      if (metodo === 'GET') { const k = Object.keys(this.datos).find(c => (u.pathname + u.search).indexOf(c) >= 0); return responder(200, JSON.stringify(k ? this.datos[k] : (u.pathname.endsWith('/licencias') ? LICENCIA : []))); }   /* datos de prueba por ruta */
      let eco = {}; try { eco = JSON.parse(p.request.postData || '{}'); } catch { }   /* como Supabase con Prefer: return=representation */
      return responder(metodo === 'POST' ? 201 : 200, metodo === 'POST' ? JSON.stringify([Object.assign({ id: 'simulado-' + this.supabase.length }, eco)]) : '[]');
    }
    if (u.hostname === 'fonts.googleapis.com') return responder(200, '', 'text/css');
    this.externas.push(p.request.url);
    return this.cmd('Fetch.failRequest', { requestId: id, errorReason: 'BlockedByClient' });
  }
  /* Retiene las escrituras a Supabase hasta llamar a la funcion devuelta (simula un guardado lento) */
  retenerEscrituras() { let liberar; this.retener = new Promise(r => { liberar = () => { this.retener = null; r(); }; }); return liberar; }
  async emular(modo) {
    if (modo === 'movil') {
      await this.cmd('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
      await this.cmd('Emulation.setTouchEmulationEnabled', { enabled: true });
    } else {
      await this.cmd('Emulation.setTouchEmulationEnabled', { enabled: false });
      await this.cmd('Emulation.setDeviceMetricsOverride', { width: 1366, height: 768, deviceScaleFactor: 1, mobile: false });
    }
  }
  async ir(url) {
    const cargada = new Promise(ok => { const off = this.con.on(m => { if (m.sessionId === this.sid && m.method === 'Page.loadEventFired') { off(); ok(); } }); });
    await this.cmd('Page.navigate', { url });
    await Promise.race([cargada, sleep(15000)]);
  }
  async recargar() {
    const cargada = new Promise(ok => { const off = this.con.on(m => { if (m.sessionId === this.sid && m.method === 'Page.loadEventFired') { off(); ok(); } }); });
    await this.cmd('Page.reload');
    await Promise.race([cargada, sleep(15000)]);
  }
  async evaluar(expresion) {
    const r = await this.cmd('Runtime.evaluate', { expression: expresion, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error('evaluar: ' + (r.exceptionDetails.exception && r.exceptionDetails.exception.description || r.exceptionDetails.text));
    return r.result.value;
  }
  async esperar(expresion, ms, que) {
    const fin = Date.now() + (ms || 10000);
    for (;;) {
      let v; try { v = await this.evaluar(expresion); } catch { v = false; }
      if (v) return v;
      if (Date.now() > fin) throw new Error('tiempo agotado esperando: ' + (que || expresion));
      await sleep(100);
    }
  }
  async centro(selector) {
    return this.evaluar("(function(){var e=document.querySelector(" + JSON.stringify(selector) + ");if(!e)return null;e.scrollIntoView({block:'center'});var r=e.getBoundingClientRect();return{x:r.left+r.width/2,y:r.top+r.height/2,w:r.width,h:r.height};})()");
  }
  async clic(selector) {
    /* Se espera a que el elemento deje de moverse (animaciones de apertura de los formularios) para no tocar donde ya no esta */
    let c = await this.centro(selector);
    for (let i = 0; i < 20 && c; i++) {
      await sleep(120);
      const d = await this.centro(selector);
      if (d && Math.abs(d.x - c.x) < 0.5 && Math.abs(d.y - c.y) < 0.5 && Math.abs(d.w - c.w) < 0.5) { c = d; break; }
      c = d;
    }
    if (!c) throw new Error('no existe ' + selector);
    if (this.op.movil) {                                   /* en el movil se toca con el dedo */
      await this.cmd('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: c.x, y: c.y }] });
      await this.cmd('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
      return;
    }
    for (const tipo of ['mousePressed', 'mouseReleased']) await this.cmd('Input.dispatchMouseEvent', { type: tipo, x: c.x, y: c.y, button: 'left', clickCount: 1 });
  }
  async escribir(selector, texto) {
    /* Los formularios de la aplicacion enfocan su primer campo con un pequeno retraso: se comprueba que el foco sigue en el campo antes de escribir */
    const sel = JSON.stringify(selector);
    for (let i = 0; i < 5; i++) {
      await this.evaluar("document.querySelector(" + sel + ").focus();true");
      await sleep(80);
      if (await this.evaluar("document.activeElement===document.querySelector(" + sel + ")")) break;
    }
    await this.cmd('Input.insertText', { text: texto });
  }
  async enfocar(selector) { await this.evaluar("document.querySelector(" + JSON.stringify(selector) + ").focus();true"); }
  /* Teclas reales (eventos de confianza): cambian selectores y fechas como lo haria una persona */
  async tecla(key) {
    const vk = { ArrowDown: 40, ArrowUp: 38, Backspace: 8, Enter: 13, Tab: 9 }[key];
    await this.cmd('Input.dispatchKeyEvent', { type: 'rawKeyDown', key, code: key, windowsVirtualKeyCode: vk });
    await this.cmd('Input.dispatchKeyEvent', { type: 'keyUp', key, code: key, windowsVirtualKeyCode: vk });
  }
  async digitos(texto) {
    for (const ch of texto) {
      await this.cmd('Input.dispatchKeyEvent', { type: 'keyDown', key: ch, text: ch, unmodifiedText: ch, windowsVirtualKeyCode: ch.charCodeAt(0) });
      await this.cmd('Input.dispatchKeyEvent', { type: 'keyUp', key: ch, windowsVirtualKeyCode: ch.charCodeAt(0) });
    }
  }
  async sinConexion(si) { await this.cmd('Network.emulateNetworkConditions', { offline: !!si, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }); }
  async captura(ruta) {
    fs.mkdirSync(path.dirname(ruta), { recursive: true });
    const r = await this.cmd('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(ruta, Buffer.from(r.data, 'base64'));
    return ruta;
  }
  async cerrar() { try { this.off && this.off(); await this.con.enviar('Target.closeTarget', { targetId: this.targetId }); } catch { } }
}
module.exports = { lanzar, sleep };
