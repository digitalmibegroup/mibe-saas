'use strict';
/* Ensayo LOCAL de la comprobacion de recuperacion (RECUPERAR-HOTFIX-EN-STAGING.ps1): REVERTIR conservando el registro con operaciones ->
   estado -> reinstalar la VARIANTE de staging -> VERIFICAR, todo como administrador SIN superusuario (supa_adm: dueno de las tablas y del
   esquema, solo ADMIN sobre cotconv_ejecutor) en una base v5 + H1. Comprueba lo mismo que el lanzador, con los mismos archivos SQL. */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path');
const { crearFetch } = require('../pg/postgrest-shim.cjs');
const RAIZ = path.join(__dirname, '..', '..', '..');
const INTEGRACION = process.env.LACAVA_INTEGRACION || 'C:/Users/USUARIO/Proyectos - Claude code/La Cava licorera/mibe-saas-integracion-compras';
const SKIP = !fs.existsSync(INTEGRACION) && 'falta la copia de integracion (solo lectura)';
const SQL = n => path.join(RAIZ, n);
const TABLAS = ['cotizaciones', 'clientes_frecuentes', 'inventario', 'ventas', 'detalle_ventas', 'cartera', 'cartera_abonos', 'licencias', 'cotizacion_conversiones'];
let B = null;
const admin = ruta => B.psql(`SET ROLE supa_adm;\n\\i '${ruta.split('\\').join('/')}'`, null);
const lineas = (r, pref) => { assert.ok(r.ok, r.err); return r.out.split('\n').map(x => x.trim()).filter(x => x.startsWith(pref)); };
const captura = () => lineas(B.psql('', null, SQL('ANON_ENSAYO_STAGING_CAPTURA.sql')), 'CAPT|');
const verificar = () => { const r = B.psql('', null, SQL('HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql')); assert.ok(r.ok, r.err); return r.out.split('\n').map(x => x.trim()).filter(Boolean); };
const ordenarAcl = s => { const m = /^(.*\{)(.*)(\}.*)$/.exec(s); return m ? m[1] + m[2].split(',').sort().join(',') + m[3] : s; };
const sinEjecutor = s => { const m = /^(.*\{)(.*)(\}.*)$/.exec(s); return m ? m[1] + m[2].split(',').filter(x => x && !x.startsWith('cotconv_ejecutor=')).sort().join(',') + m[3] : s; };
const esHotfix = s => /cotconv_|convertir_cotizacion_atomica|cotizacion_conversion_info|cotizacion_conversiones/.test(s);
const COTS = [1, 2, 3].map(n => `c0c0c0c0-0000-4000-8000-00000000000${n}`);
const ver = n => B.ok(`SELECT updated_at FROM cotizaciones WHERE id='${COTS[n]}'`);

before(async () => {
  if (SKIP) return;
  const { construir } = require('./base-h1.cjs'); B = await construir();
  assert.ok(B.psql('', null, SQL('HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql')).ok);
  B.ok(`INSERT INTO inventario (id, nombre, categoria, precio_venta, precio_costo, stock, uds_sueltas, uds_empaque, id_licencia) VALUES ('ens-ron','Ron 750 (ENSAYO)','Ensayo',80000,50000,100,0,1,'lacava');
    INSERT INTO clientes_frecuentes (id,nombre,whatsapp,direccion,detalle,id_licencia) VALUES ('5e5e5e5e-0000-4000-8000-0000000000e1','Cliente Ficticio (ENSAYO)','3000000001','Calle 1','Apto 1','lacava');
    ${COTS.map((id, i) => `INSERT INTO cotizaciones (id,id_licencia,numero_local,numero,cliente_nombre,cliente_whatsapp,estado,items,total,fecha_creacion) VALUES ('${id}','lacava',${i + 1},${i + 1},'Cliente Ficticio (ENSAYO)','3000000001','aprobada','[{"prod_id":"ens-ron","nombre":"Ron 750 (ENSAYO)","cantidad":1,"precio_unitario":80000,"precio_total":80000,"tipo":"und","_precioBase":80000,"descItem":0}]',80000,now());`).join('\n')}`);
  /* dos conversiones reales (como authenticated con perfil) -> el registro tiene operaciones */
  const f = crearFetch(B);
  for (const n of [0, 1]) {
    const r = await f('https://x/rest/v1/rpc/convertir_cotizacion_atomica', { method: 'POST', rol: 'authenticated', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ p_id_licencia: 'lacava', p_cotizacion_id: COTS[n], p_op_clave: 'conv-' + require('node:crypto').randomUUID(), p_cotizacion_updated_at: ver(n), p_pago: { tipo: 'efectivo', total_esperado: 80000 }, p_cliente_id: '5e5e5e5e-0000-4000-8000-0000000000e1', p_entrega: {} }) });
    assert.equal(r.status, 200, await r.text());
  }
  /* administrador sin superusuario, como el rol postgres de Supabase */
  B.ok(`CREATE ROLE supa_adm NOLOGIN CREATEROLE NOSUPERUSER; GRANT cotconv_ejecutor TO supa_adm WITH ADMIN OPTION, INHERIT FALSE, SET FALSE; ALTER SCHEMA public OWNER TO supa_adm;`);
  for (const t of TABLAS) B.ok('ALTER TABLE public.' + t + ' OWNER TO supa_adm');
  B.ok('ALTER FUNCTION public.cotconv_registro_inmutable() OWNER TO supa_adm'); /* la funcion del disparador la crea el administrador, como en Supabase */
});
after(() => { if (B) B.detener(); });

test('recuperacion completa: REVERTIR (registro conservado) -> verificar -> reinstalar la variante -> verificar', { skip: SKIP, timeout: 300000 }, async () => {
  const antes = captura();
  const datosAntes = B.ok(`SELECT (SELECT count(*) FROM ventas)||'/'||(SELECT count(*) FROM detalle_ventas)||'/'||(SELECT count(*) FROM cotizaciones)||'/'||(SELECT count(*) FROM clientes_frecuentes)||'/'||(SELECT stock FROM inventario WHERE id='ens-ron')||'/'||(SELECT count(*) FROM app.perfiles_usuario)`);
  assert.equal(B.ok(`SELECT count(*) FROM cotizacion_conversiones`), '2');

  /* 1) REVERTIR como administrador sin superusuario */
  const rev = admin(SQL('HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql')); assert.ok(rev.ok, rev.err);
  assert.match(rev.err, /se CONSERVO public\.cotizacion_conversiones con 2 operacion/);
  const v1 = verificar();
  assert.ok(v1.includes('RESULTADO|NO_INSTALADO'));
  assert.equal(v1.filter(l => l.startsWith('FUNCION|')).length, 0, 'las RPC se retiraron');
  assert.ok(v1.some(l => /^REGISTRO\|operaciones=2\|con_venta_eliminada=0/.test(l)), 'el registro conserva sus operaciones');
  assert.ok(v1.includes('PRIVILEGIO|anon|cotizacion_conversiones|') && v1.includes('PRIVILEGIO|authenticated|cotizacion_conversiones|'), 'registro cerrado');
  assert.ok(v1.some(l => l.startsWith('DISPARADOR|')), 'el registro conserva su proteccion de solo anadir');
  assert.equal(B.ok(`SELECT count(*) FROM pg_roles WHERE rolname='cotconv_ejecutor'`), '0');
  assert.equal(B.ok(`SELECT count(*) FROM pg_policies WHERE policyname LIKE 'cotconv\\_%'`), '0');
  const post = captura();
  const norm = c => c.map(sinEjecutor).filter(l => !esHotfix(l) && !/^CAPT\|columna\|.*\|acl=\{\}$/.test(l)).sort(); /* una columna que solo tenia permisos del ejecutor queda sin ACL */
  assert.ok(norm(antes).length > 100, 'la comparacion es significativa (' + norm(antes).length + ' lineas)');
  assert.deepEqual(norm(post), norm(antes), 'H1 y los permisos ajenos al hotfix quedan intactos');
  assert.ok(post.filter(l => /\|h1_/.test(l)).length > 0 && post.filter(l => /\|h1_/.test(l)).length === antes.filter(l => /\|h1_/.test(l)).length, 'politicas H1 intactas');
  assert.equal(B.ok(`SELECT (SELECT count(*) FROM ventas)||'/'||(SELECT count(*) FROM detalle_ventas)||'/'||(SELECT count(*) FROM cotizaciones)||'/'||(SELECT count(*) FROM clientes_frecuentes)||'/'||(SELECT stock FROM inventario WHERE id='ens-ron')||'/'||(SELECT count(*) FROM app.perfiles_usuario)`), datosAntes, 'datos intactos');
  /* con las RPC retiradas, convertir no se puede */
  const f = crearFetch(B);
  const sin = await f('https://x/rest/v1/rpc/convertir_cotizacion_atomica', { method: 'POST', rol: 'authenticated', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ p_id_licencia: 'lacava', p_cotizacion_id: COTS[2], p_op_clave: 'conv-' + require('node:crypto').randomUUID(), p_cotizacion_updated_at: ver(2), p_pago: { tipo: 'efectivo' }, p_cliente_id: null, p_entrega: {} }) });
  assert.ok([404, 400].includes(sin.status), 'conversion indisponible: ' + sin.status);

  /* 2) REINSTALAR la variante de staging, una sola transaccion, como administrador sin superusuario */
  const inst = admin(SQL('HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql')); assert.ok(inst.ok, inst.err);
  assert.match(inst.err, /se reutiliza el registro existente/);
  const v2 = verificar();
  assert.ok(v2.includes('RESULTADO|INSTALADO')); assert.equal(v2.filter(l => l.startsWith('ERROR|')).length, 0, v2.join('\n'));
  assert.equal(v2.filter(l => l.startsWith('FUNCION|')).length, 2);
  for (const l of v2.filter(l => l.startsWith('FUNCION|'))) assert.match(l, /definer=true\|dueno=cotconv_ejecutor\|.*\|anon_exec=false\|auth_exec=true\|public_exec=false$/);
  assert.ok(v2.some(l => /^REGISTRO\|operaciones=2\|/.test(l)), 'el registro se reutiliza');
  assert.equal(B.ok(`SELECT count(*) FROM pg_auth_members WHERE roleid='cotconv_ejecutor'::regrole AND (set_option OR inherit_option)`), '0', 'sin membresias temporales');
  assert.equal(B.ok(`SELECT count(*) FROM pg_policies WHERE policyname LIKE 'cotconv\\_%'`), '15');
  assert.equal(B.ok(`SELECT has_function_privilege('anon','public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb)','EXECUTE')`), 'f');
  assert.deepEqual(captura().map(ordenarAcl).sort(), antes.map(ordenarAcl).sort(), 'la captura final es IDENTICA a la inicial');

  /* 3) funciones operativas: el registro reutilizado responde y una conversion nueva funciona */
  const info = await f('https://x/rest/v1/rpc/cotizacion_conversion_info', { method: 'POST', rol: 'authenticated', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ p_id_licencia: 'lacava', p_cotizacion_id: COTS[0] }) });
  const ij = await info.json(); assert.equal(info.status, 200); assert.equal(ij.operaciones.length, 1); assert.equal(ij.operaciones[0].venta_existe, true);
  const nueva = await f('https://x/rest/v1/rpc/convertir_cotizacion_atomica', { method: 'POST', rol: 'authenticated', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ p_id_licencia: 'lacava', p_cotizacion_id: COTS[2], p_op_clave: 'conv-' + require('node:crypto').randomUUID(), p_cotizacion_updated_at: ver(2), p_pago: { tipo: 'efectivo', total_esperado: 80000 }, p_cliente_id: '5e5e5e5e-0000-4000-8000-0000000000e1', p_entrega: {} }) });
  assert.equal(nueva.status, 200); assert.equal((await nueva.json()).ok, true);
  assert.equal(B.ok(`SELECT count(*) FROM cotizacion_conversiones`), '3');
  const anon = B.psql(`SELECT public.cotizacion_conversion_info('lacava','${COTS[0]}')`, 'anon'); assert.equal(anon.ok, false); assert.equal(anon.codigo, '42501', 'anon sigue sin EXECUTE');
});
