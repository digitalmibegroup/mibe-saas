'use strict';
/* El guion de restablecimiento de contrasena, contra un Supabase Auth FALSO en memoria: solo cambia la contrasena, rechaza
   produccion y usuarios que no son el del perfil o no son ficticios, y nunca revela credenciales. */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { restablecer } = require('./restablecer-contrasena-ensayo.cjs');
const URL_STAGING = 'https://aaaaaaaaaaaaaaaaaaaa.supabase.co'; /* ficticia: el Auth es falso; la huella real se valida aparte */
const OK = () => null;
const UID = '5a5a5a5a-1111-4111-8111-aaaaaaaaaaaa';
const ADMIN = 'ADMIN-SECRETA-FICTICIA-0000000000', PUB = 'PUBLICA-FICTICIA-000000000000', NUEVA = 'Nueva-Contrasena-Ficticia-77';

function falso(opc) {
  const o = Object.assign({ email: 'ensayo@ficticio.invalid', id: UID, password: 'vieja-ficticia', loginOk: true, perfil: true }, opc);
  const llamadas = [];
  const fn = async (url, init) => {
    init = init || {}; const m = (init.method || 'GET').toUpperCase(); const u = new URL(url); llamadas.push({ m, ruta: u.pathname, cuerpo: init.body ? JSON.parse(init.body) : null, auth: (init.headers || {}).Authorization });
    const r = (st, j) => new Response(JSON.stringify(j), { status: st });
    if (u.pathname === '/auth/v1/admin/users/' + UID) {
      if (init.headers.Authorization !== 'Bearer ' + ADMIN) return r(401, {});
      if (m === 'GET') return r(200, { id: o.id, email: o.email });
      if (m === 'PUT') { const b = JSON.parse(init.body); if (b.password) o.password = b.password; return r(200, { id: o.id, email: o.email }); }
    }
    if (u.pathname.startsWith('/auth/v1/admin/users/')) return r(404, {});
    if (u.pathname === '/auth/v1/token') { const b = JSON.parse(init.body); return (o.loginOk && b.password === o.password && b.email === o.email) ? r(200, { access_token: 'JWT-FALSO', user: { id: o.id } }) : r(400, {}); }
    if (u.pathname === '/rest/v1/rpc/lacava_mi_sesion') return o.perfil ? r(200, { licencia: 'lacava', rol: 'operador_principal', ventas_habilitadas: true }) : r(400, { message: 'sin perfil' });
    return r(404, {});
  };
  return { fn, llamadas, estado: o };
}

test('cambia SOLO la contraseña: UUID y correo intactos, acceso verificado, sin credenciales en el informe', async () => {
  const f = falso();
  const r = await restablecer({ url: URL_STAGING, claveAdmin: ADMIN, clavePublica: PUB, nuevaClave: NUEVA, uuid: UID, fetchFn: f.fn, validarFn: OK });
  assert.deepEqual(r, { uuid_conservado: true, correo_conservado: true, acceso_verificado: true, perfil: { licencia: 'lacava', rol: 'operador_principal', ventas_habilitadas: true } });
  const puts = f.llamadas.filter(x => x.m === 'PUT');
  assert.equal(puts.length, 1); assert.deepEqual(Object.keys(puts[0].cuerpo), ['password'], 'el cuerpo solo trae la contraseña');
  assert.equal(f.estado.password, NUEVA); assert.equal(f.estado.id, UID); assert.equal(f.estado.email, 'ensayo@ficticio.invalid');
  assert.doesNotMatch(JSON.stringify(r), new RegExp(ADMIN + '|' + PUB + '|' + NUEVA + '|JWT-FALSO'));
  assert.deepEqual(f.llamadas.map(x => x.m + ' ' + x.ruta), ['GET /auth/v1/admin/users/' + UID, 'PUT /auth/v1/admin/users/' + UID, 'POST /auth/v1/token', 'POST /rest/v1/rpc/lacava_mi_sesion']);
});
test('rechaza producción y proyectos que no son el staging, sin llamar a nada', async () => {
  for (const url of ['https://egjlrcokerffuoqwbxlh.supabase.co', 'https://aaaaaaaaaaaaaaaaaaaa.supabase.co', 'http://localhost']) {
    const f = falso();
    await assert.rejects(() => restablecer({ url, claveAdmin: ADMIN, clavePublica: PUB, nuevaClave: NUEVA, uuid: UID, fetchFn: f.fn }));
    assert.equal(f.llamadas.length, 0);
  }
});
test('no escribe si el UUID no existe, no es válido, el correo no es .invalid o la clave es corta', async () => {
  let f = falso();
  await assert.rejects(() => restablecer({ url: URL_STAGING, claveAdmin: ADMIN, clavePublica: PUB, nuevaClave: NUEVA, uuid: '5a5a5a5a-2222-4222-8222-bbbbbbbbbbbb', fetchFn: f.fn, validarFn: OK }), /No existe un usuario/);
  assert.equal(f.llamadas.filter(x => x.m === 'PUT').length, 0);
  await assert.rejects(() => restablecer({ url: URL_STAGING, claveAdmin: ADMIN, clavePublica: PUB, nuevaClave: NUEVA, uuid: 'no-es-uuid', fetchFn: falso().fn, validarFn: OK }), /UUID/);
  f = falso({ email: 'persona@correo.com' });
  await assert.rejects(() => restablecer({ url: URL_STAGING, claveAdmin: ADMIN, clavePublica: PUB, nuevaClave: NUEVA, uuid: UID, fetchFn: f.fn, validarFn: OK }), /NO termina en \.invalid/);
  assert.equal(f.llamadas.filter(x => x.m === 'PUT').length, 0); assert.equal(f.estado.password, 'vieja-ficticia');
  f = falso();
  await assert.rejects(() => restablecer({ url: URL_STAGING, claveAdmin: ADMIN, clavePublica: PUB, nuevaClave: 'corta', uuid: UID, fetchFn: f.fn, validarFn: OK }), /al menos 12/);
  assert.equal(f.llamadas.length, 0);
});
test('una clave administrativa equivocada no cambia nada y los errores no contienen credenciales', async () => {
  const f = falso();
  await assert.rejects(() => restablecer({ url: URL_STAGING, claveAdmin: 'OTRA-CLAVE-FICTICIA-0000000000', clavePublica: PUB, nuevaClave: NUEVA, uuid: UID, fetchFn: f.fn, validarFn: OK }), e => { assert.doesNotMatch(e.message, new RegExp(ADMIN + '|OTRA-CLAVE|' + NUEVA)); return /clave administrativa/.test(e.message); });
  assert.equal(f.estado.password, 'vieja-ficticia');
});
test('si el acceso con la nueva contraseña falla o no hay perfil, lo informa sin revelar valores', async () => {
  await assert.rejects(() => restablecer({ url: URL_STAGING, claveAdmin: ADMIN, clavePublica: PUB, nuevaClave: NUEVA, uuid: UID, fetchFn: falso({ loginOk: false }).fn, validarFn: OK }), /NO permite iniciar sesion/);
  await assert.rejects(() => restablecer({ url: URL_STAGING, claveAdmin: ADMIN, clavePublica: PUB, nuevaClave: NUEVA, uuid: UID, fetchFn: falso({ perfil: false }).fn, validarFn: OK }), e => { assert.doesNotMatch(e.message, new RegExp(NUEVA)); return /no confirma el perfil/.test(e.message); });
});
test('línea de comandos: sin --uuid o con producción termina sin hacer nada', () => {
  const cli = path.join(__dirname, 'restablecer-contrasena-ensayo.cjs');
  assert.equal(spawnSync(process.execPath, [cli], { encoding: 'utf8', timeout: 20000 }).status, 2);
  const p = spawnSync(process.execPath, [cli, '--uuid', UID], { input: 'https://egjlrcokerffuoqwbxlh.supabase.co\n', encoding: 'utf8', timeout: 20000 });
  assert.equal(p.status, 4); assert.match(p.stderr, /PRODUCCION/);
});
