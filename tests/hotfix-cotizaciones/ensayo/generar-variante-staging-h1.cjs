'use strict';
/* Genera HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql a partir del SQL destinado a produccion, SIN modificar este.
   La variante es SOLO para el ensayo en el staging (v5 + H1): nunca concede EXECUTE a anon (en ningun momento de la
   transaccion), retira toda membresia temporal del instalador y verifica de forma estricta los permisos finales.
   Cada reemplazo exige que el ancla exista exactamente una vez; si no, no genera nada.
   Uso: node generar-variante-staging-h1.cjs [--verificar]   (--verificar: falla si el archivo generado no coincide) */
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const RAIZ = path.join(__dirname, '..', '..', '..');
const ORIGEN = path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA.sql');
const DESTINO = path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql');
const FN1 = 'public.convertir_cotizacion_atomica(text,uuid,text,timestamptz,jsonb,uuid,jsonb)';
const FN2 = 'public.cotizacion_conversion_info(text,uuid)';

function generar() {
  let s = fs.readFileSync(ORIGEN, 'utf8').replace(/\r\n/g, '\n');
  const cambiar = (ancla, nuevo, etiqueta) => {
    const n = s.split(ancla).length - 1;
    if (n !== 1) throw new Error(`ancla "${etiqueta}" aparece ${n} veces (se esperaba 1)`);
    s = s.replace(ancla, () => nuevo);
  };
  /* 1) EXECUTE solo para authenticated: anon nunca lo recibe */
  cambiar(`GRANT EXECUTE ON FUNCTION ${FN1} TO anon, authenticated;\nGRANT EXECUTE ON FUNCTION ${FN2} TO anon, authenticated;`,
    `-- ENSAYO H1: EXECUTE solo para authenticated. anon NO lo recibe en ningun momento de esta transaccion.\n` +
    `GRANT EXECUTE ON FUNCTION ${FN1} TO authenticated;\nGRANT EXECUTE ON FUNCTION ${FN2} TO authenticated;\n` +
    `REVOKE EXECUTE ON FUNCTION ${FN1} FROM anon;\nREVOKE EXECUTE ON FUNCTION ${FN2} FROM anon;\n` +
    `-- La funcion del disparador tampoco debe quedar ejecutable por PUBLIC/anon/authenticated (un disparador no la necesita para dispararse).\n` +
    `REVOKE ALL ON FUNCTION public.cotconv_registro_inmutable() FROM PUBLIC, anon, authenticated;`, 'GRANT EXECUTE');
  /* 2) (el SQL de produccion ya retira la membresia temporal sin tolerar fallos y lo verifica antes del COMMIT) */
  /* 3) verificacion: anon NO ejecuta; authenticated SI; sin CREATE ni membresia temporal */
  cambiar(`    IF NOT has_function_privilege('anon', f::regprocedure, 'EXECUTE') OR NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN\n      RAISE EXCEPTION 'VERIFICACION: anon y authenticated deben ejecutar %', f; END IF;`,
    `    IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN RAISE EXCEPTION 'VERIFICACION (ensayo H1): anon no debe ejecutar %', f; END IF;\n` +
    `    IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN RAISE EXCEPTION 'VERIFICACION (ensayo H1): authenticated debe ejecutar %', f; END IF;`, 'verificacion de ejecucion');
  cambiar(`  IF has_schema_privilege('cotconv_ejecutor', 'public', 'CREATE') THEN RAISE EXCEPTION 'VERIFICACION: cotconv_ejecutor no debe tener CREATE en public'; END IF;`,
    `  IF has_schema_privilege('cotconv_ejecutor', 'public', 'CREATE') THEN RAISE EXCEPTION 'VERIFICACION: cotconv_ejecutor no debe tener CREATE en public'; END IF;\n` +
    `  -- ENSAYO H1: ninguna funcion del hotfix (incluida la del disparador) ejecutable por anon, authenticated ni PUBLIC, salvo las dos RPC para authenticated\n` +
    `  IF has_function_privilege('anon', 'public.cotconv_registro_inmutable()'::regprocedure, 'EXECUTE') OR has_function_privilege('authenticated', 'public.cotconv_registro_inmutable()'::regprocedure, 'EXECUTE')\n` +
    `     OR has_function_privilege('public', 'public.cotconv_registro_inmutable()'::regprocedure, 'EXECUTE') THEN\n` +
    `    RAISE EXCEPTION 'VERIFICACION (ensayo H1): la funcion del disparador no debe ser ejecutable por anon, authenticated ni PUBLIC'; END IF;`, 'verificacion de CREATE');
  const cabecera = `-- ============================================================================
-- VARIANTE SOLO PARA EL ENSAYO EN EL STAGING ca10112ba2 (Compras v5 + H1). NO ES EL SQL DE PRODUCCION.
-- Generada por tests/hotfix-cotizaciones/ensayo/generar-variante-staging-h1.cjs a partir de HOTFIX_COT_CONVERSION_ATOMICA.sql
-- (que se conserva para produccion; ese SQL ya retira la membresia temporal sin tolerar fallos y lo verifica). Diferencias, todas dentro de la MISMA transaccion (un solo BEGIN y un solo COMMIT):
--   1. EXECUTE de las dos funciones SOLO para authenticated; anon no lo recibe en ningun momento (y se revoca de forma explicita).
--   2. La funcion del disparador queda sin EXECUTE para PUBLIC, anon y authenticated.
--   3. La verificacion final exige: anon no ejecuta ninguna funcion del hotfix y authenticated si ejecuta las dos RPC (el resto de
--      verificaciones, incluida la ausencia de membresia temporal, son las de produccion). Si algo falla, se deshace toda la instalacion.
-- Motivo: bajo H1 no hay acceso anonimo; el EXECUTE para anon del SQL de produccion lo reabriria. Ver PLAN_ENSAYO_HOTFIX_EN_STAGING.md.
-- ============================================================================
`;
  s = cabecera + s;
  const begins = (s.match(/^BEGIN;$/gm) || []).length, commits = (s.match(/^COMMIT;$/gm) || []).length;
  if (begins !== 1 || commits !== 1) throw new Error(`debe haber exactamente un BEGIN y un COMMIT (hay ${begins} y ${commits})`);
  if (/TO\s+anon\b/i.test(s.split('\n').filter(l => !/^\s*--/.test(l) && /GRANT\s+EXECUTE/i.test(l)).join('\n'))) throw new Error('la variante concede EXECUTE a anon');
  return s;
}
if (require.main === module) {
  const nuevo = generar();
  if (process.argv.includes('--verificar')) {
    const actual = fs.existsSync(DESTINO) ? fs.readFileSync(DESTINO, 'utf8').replace(/\r\n/g, '\n') : '';
    if (actual !== nuevo) { console.error('La variante generada NO coincide con ' + path.basename(DESTINO)); process.exit(1); }
    console.log('La variante coincide con el generador.');
  } else { fs.writeFileSync(DESTINO, nuevo); console.log('Generado ' + path.basename(DESTINO) + ' sha256 ' + crypto.createHash('sha256').update(nuevo).digest('hex')); }
}
module.exports = { generar, DESTINO };
