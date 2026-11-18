'use strict';
/* El instalador de PRODUCCION concede EXECUTE a anon y a authenticated de forma EFECTIVA y lo verifica antes del COMMIT.
   Se ejecuta como supa_postgres: administrador SIN superusuario que posee las tablas y solo tiene ADMIN (sin SET ni INHERIT)
   sobre el rol ejecutor, como el postgres de Supabase. Un GRANT/REVOKE de EXECUTE hecho por un no-dueno SIN membresia no hace nada
   (solo avisa): por eso se prueban mutaciones del instalador que reproducen ese defecto y deben FALLAR sin dejar nada instalado. */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { disponible, iniciar, prepararBase, RAIZ } = require('./pg-temporal.cjs');

const INSTALAR = path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA.sql');
const REVERTIR = path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql');
const TEXTO = fs.readFileSync(INSTALAR, 'utf8').replace(/\r\n/g, '\n');
const FN = ['public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb)', 'public.cotizacion_conversion_info(text,uuid)'];
const GRANTS = FN.map(f => `GRANT EXECUTE ON FUNCTION ${f} TO anon, authenticated;`);
const REVOKE_MEMB = "  EXECUTE format('REVOKE cotconv_ejecutor FROM %I', current_user);";
let pg = null, tmp = null;
const SKIP = !disponible() && 'PostgreSQL portable no disponible';
const uno = q => pg.sql(q).out;
const estado = () => ({ funciones: uno(`SELECT count(*) FROM pg_proc WHERE proname IN ('convertir_cotizacion_atomica','cotizacion_conversion_info')`), rol: uno(`SELECT count(*) FROM pg_roles WHERE rolname='cotconv_ejecutor'`), registro: uno(`SELECT count(*) FROM pg_class WHERE relname='cotizacion_conversiones'`) });
const mutar = (nombre, fn) => { const t = fn(TEXTO); assert.notEqual(t, TEXTO, nombre + ': la mutacion no cambio nada'); const f = path.join(tmp, nombre + '.sql'); fs.writeFileSync(f, t); return f; };
const reinstalar = () => { const r = pg.archivoSeguro(REVERTIR); assert.ok(r.ok, r.err); const i = pg.archivoSeguro(INSTALAR); assert.ok(i.ok, i.err); };

before(() => { if (SKIP) return; tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lacava-instprod-')); pg = iniciar(); prepararBase(pg); });
after(() => { if (pg) pg.detener(); if (tmp) fs.rmSync(tmp, { recursive: true, force: true }); });

test('instalacion real como administrador sin superusuario: EXECUTE efectivo para anon y authenticated, y sin membresia temporal', { skip: SKIP }, () => {
  assert.equal(uno(`SELECT rolsuper FROM pg_roles WHERE rolname='supa_postgres'`), 'f', 'el administrador de la prueba NO es superusuario');
  for (const f of FN) {
    assert.equal(uno(`SELECT has_function_privilege('anon','${f}','EXECUTE')`), 't', f + ' anon');
    assert.equal(uno(`SELECT has_function_privilege('authenticated','${f}','EXECUTE')`), 't', f + ' authenticated');
    assert.equal(uno(`SELECT has_function_privilege('public','${f}','EXECUTE')`), 'f', f + ' PUBLIC');
    const acl = uno(`SELECT proacl::text FROM pg_proc WHERE oid='${f}'::regprocedure`);
    assert.match(acl, /anon=X\/cotconv_ejecutor/, 'la concesion la registra el dueno de la funcion: ' + acl);
  }
  assert.equal(uno(`SELECT count(*) FROM pg_auth_members WHERE roleid='cotconv_ejecutor'::regrole AND member='supa_postgres'::regrole AND (set_option OR inherit_option)`), '0', 'sin membresia temporal con SET/INHERIT');
  /* anon la ejecuta de verdad (no "permission denied"): con una cotizacion inexistente responde un error de negocio o un resultado vacio */
  const info = pg.sql(`SELECT public.cotizacion_conversion_info('lacava','00000000-0000-4000-8000-000000000000')`, { rol: 'anon' });
  assert.ok(info.ok, info.err); assert.deepEqual(JSON.parse(info.out.split('\n').pop()), { operaciones: [] });
  const conv = pg.sql(`SELECT public.convertir_cotizacion_atomica('lacava','00000000-0000-4000-8000-000000000000','conv-x',now(),'{"tipo":"efectivo"}'::jsonb,NULL,'{}'::jsonb)`, { rol: 'anon' });
  assert.equal(conv.ok, false); assert.notEqual(conv.codigo, '42501', 'anon no debe recibir "permission denied": ' + conv.err); assert.match(conv.codigo || '', /^CV/);
});

test('defecto reproducido: GRANT EXECUTE tras retirar la membresia no surte efecto, y el instalador lo detecta antes del COMMIT y no deja nada', { skip: SKIP }, () => {
  assert.ok(pg.archivoSeguro(REVERTIR).ok);
  const f = mutar('grant-despues', t => { let x = t; for (const g of GRANTS) x = x.replace(g + '\n', ''); return x.replace('END $rm$;\n', 'END $rm$;\n' + GRANTS.join('\n') + '\n'); });
  const r = pg.archivoSeguro(f);
  assert.equal(r.ok, false, 'debe fallar');
  assert.match(r.err, /VERIFICACION: anon y authenticated deben ejecutar/);
  assert.match(r.err, /no privileges were granted|01007|VERIFICACION/);
  assert.deepEqual(estado(), { funciones: '0', rol: '0', registro: '0' }, 'no queda nada instalado');
});

test('instalador sin GRANT EXECUTE: se detiene antes del COMMIT y no deja nada', { skip: SKIP }, () => {
  const f = mutar('sin-grant', t => { let x = t; for (const g of GRANTS) x = x.replace(g + '\n', ''); return x; });
  const r = pg.archivoSeguro(f);
  assert.equal(r.ok, false); assert.match(r.err, /VERIFICACION: anon y authenticated deben ejecutar/);
  assert.deepEqual(estado(), { funciones: '0', rol: '0', registro: '0' });
});

test('instalador que no retira la membresia temporal: se detiene (antes toleraba el fallo y solo avisaba) y no deja nada', { skip: SKIP }, () => {
  const f = mutar('sin-retirar', t => t.replace(REVOKE_MEMB, '  NULL;'));
  const r = pg.archivoSeguro(f);
  assert.equal(r.ok, false); assert.match(r.err, /VERIFICACION: quedo una membresia temporal/);
  assert.deepEqual(estado(), { funciones: '0', rol: '0', registro: '0' });
  assert.ok(!/EXCEPTION WHEN OTHERS\s+THEN\s+RAISE NOTICE 'No se pudo retirar la membresia/.test(TEXTO), 'el instalador ya no tolera el fallo');
});

test('el instalador intacto vuelve a instalarse y queda efectivo', { skip: SKIP }, () => {
  const i = pg.archivoSeguro(INSTALAR); assert.ok(i.ok, i.err);
  for (const f of FN) assert.equal(uno(`SELECT has_function_privilege('anon','${f}','EXECUTE') AND has_function_privilege('authenticated','${f}','EXECUTE')`), 't');
  assert.deepEqual(estado(), { funciones: '2', rol: '1', registro: '1' });
  const v = pg.archivoSeguro(path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql')); assert.ok(v.ok, v.err);
  assert.match(v.out, /RESULTADO\|INSTALADO/); assert.ok(!/^ERROR\|/m.test(v.out), v.out);
});
