'use strict';
/* La variante de instalacion para el ensayo en staging (v5 + H1): una sola transaccion, anon nunca ejecuta, sin CREATE ni
   membresia temporal, y se deshace TODO si Supabase rechaza un paso. Base local con el paquete real v5 + H1 (solo lectura de la copia de integracion). */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path');
const { generar, DESTINO } = require('./generar-variante-staging-h1.cjs');
const { disponible, iniciar, prepararBase } = require('../pg/pg-temporal.cjs');
const RAIZ = path.join(__dirname, '..', '..', '..');
const INTEGRACION = process.env.LACAVA_INTEGRACION || 'C:/Users/USUARIO/Proyectos - Claude code/La Cava licorera/mibe-saas-integracion-compras';
const SKIP = (!disponible() && 'PostgreSQL portable no disponible') || (!fs.existsSync(INTEGRACION) && 'falta la copia de integracion (solo lectura)');
const PRE = path.join(RAIZ, 'PRECHEQUEO_HOTFIX_EN_STAGING.sql'), VER = path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql');

test('el archivo de la variante coincide con el generador y deja intacto el SQL de produccion', () => {
  assert.equal(fs.readFileSync(DESTINO, 'utf8').replace(/\r\n/g, '\n'), generar());
  const prod = fs.readFileSync(path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA.sql'), 'utf8');
  assert.match(prod, /TO anon, authenticated;/, 'el SQL de produccion conserva el EXECUTE para anon (modelo sin H1)');
  const v = fs.readFileSync(DESTINO, 'utf8');
  assert.equal((v.match(/^BEGIN;$/gm) || []).length, 1); assert.equal((v.match(/^COMMIT;$/gm) || []).length, 1, 'una sola transaccion');
  assert.doesNotMatch(v.split('\n').filter(l => !/^\s*--/.test(l) && /GRANT\s+EXECUTE/i.test(l)).join('\n'), /\banon\b/i, 'nunca se concede EXECUTE a anon');
});
test('sobre v5 + H1: se instala, anon no ejecuta nada, authenticated si, registro cerrado, permisos de H1 intactos', { skip: SKIP }, async () => {
  const { construir } = require('./base-h1.cjs'); const B = await construir();
  try {
    const norm = t => t.replace(/\r/g, '').split('\n');
    const sinEjecutor = l => l.replace(/cotconv_ejecutor=[^,}]*,?/g, '').replace(/,\}/, '}');
    const antes = norm(B.psql('', null, PRE).out);
    const inst = B.psql('', null, DESTINO); assert.ok(inst.ok, inst.err);
    const despues = norm(B.psql('', null, PRE).out);
    const ver = B.psql('', null, VER).out;
    assert.match(ver, /RESULTADO\|INSTALADO/); assert.doesNotMatch(ver, /^ERROR\|/m);
    assert.equal((ver.match(/anon_exec=false\|auth_exec=true\|public_exec=false/g) || []).length, 2);
    /* permisos y politicas de H1: lo anterior se conserva (salvo las entradas del rol ejecutor en las ACL) */
    for (const p of ['ACL|', 'ESQUEMA|', 'ACL_FUNCION|', 'POLITICA|', 'DISPARADOR|', 'SECUENCIA|', 'H1|']) {
      const a = antes.filter(l => l.startsWith(p)).map(sinEjecutor), b = despues.filter(l => l.startsWith(p)).map(sinEjecutor);
      for (const l of a) assert.ok(b.includes(l), 'cambio no esperado en ' + l.slice(0, 100));
    }
    const datos = l => l.startsWith('DATOS|') && !l.includes('cotizacion_conversiones');
    assert.deepEqual(despues.filter(datos), antes.filter(datos), 'los datos de negocio no cambiaron');
    assert.equal(B.ok(`SELECT count(*) FROM pg_auth_members WHERE roleid='cotconv_ejecutor'::regrole`), '0', 'sin membresia temporal');
    assert.equal(B.ok(`SELECT has_schema_privilege('cotconv_ejecutor','public','CREATE')`), 'f');
    for (const f of ['convertir_cotizacion_atomica', 'cotizacion_conversion_info', 'cotconv_registro_inmutable']) assert.equal(B.ok(`SELECT has_function_privilege('anon','public.${f}'::regproc,'EXECUTE')`), 'f', f);
    assert.equal(B.psql(`SELECT public.cotizacion_conversion_info('lacava','c0c0c0c0-0000-4000-8000-000000000001'::uuid)`, 'anon').codigo, '42501');
    assert.ok(B.psql(`SELECT public.cotizacion_conversion_info('lacava','c0c0c0c0-0000-4000-8000-000000000001'::uuid)`, 'lacava').ok);
    for (const q of ['anon', 'lacava']) assert.equal(B.psql(`SELECT count(*) FROM public.cotizacion_conversiones`, q).codigo, '42501');
  } finally { B.detener(); }
});
test('si el administrador no puede crear en public: falla con el error de Supabase y no queda NADA instalado', { skip: SKIP }, () => {
  const pg = iniciar();
  try {
    prepararBase(pg, false);
    pg.sql(`CREATE ROLE dbowner NOLOGIN; ALTER SCHEMA public OWNER TO dbowner; GRANT USAGE ON SCHEMA public TO supa_postgres, anon, authenticated; REVOKE CREATE ON SCHEMA public FROM supa_postgres;`);
    const r = pg.archivoSeguro(DESTINO);
    assert.equal(r.ok, false); assert.equal(r.codigo, '42501'); assert.match(r.mensaje, /permission denied for schema public/);
    assert.equal(pg.sql(`SELECT (SELECT count(*) FROM pg_roles WHERE rolname='cotconv_ejecutor')||'/'||(to_regclass('public.cotizacion_conversiones') IS NOT NULL)||'/'||(SELECT count(*) FROM pg_proc WHERE proname LIKE 'convertir_cot%' OR proname LIKE 'cotizacion_conversion%' OR proname LIKE 'cotconv%')`).out, '0/false/0');
  } finally { pg.detener(); }
});
