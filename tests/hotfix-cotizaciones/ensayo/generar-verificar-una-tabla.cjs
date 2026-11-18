'use strict';
/* Genera HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR_UNA_TABLA.sql a partir del VERIFICAR auditado: mismas consultas, en UNA sola instruccion, para el
   SQL Editor de Supabase (que solo muestra el resultado de la ultima instruccion). El original no se modifica. */
const fs = require('node:fs'), path = require('node:path');
const RAIZ = path.join(__dirname, '..', '..', '..');
const origen = fs.readFileSync(path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql'), 'utf8').replace(/\r\n/g, '\n');
const lineas = origen.split('\n');
const sentencias = []; let actual = [];
for (const l of lineas) {
  if (!actual.length && (l.trim() === '' || l.startsWith('--'))) continue;      // comentarios entre sentencias
  actual.push(l);
  if (l.trimEnd().endsWith(';')) { sentencias.push(actual.join('\n')); actual = []; }
}
if (actual.length) throw new Error('sentencia sin terminar');
const sel = sentencias.filter(s => !/^(BEGIN|ROLLBACK)\b/i.test(s.trim()));
if (sentencias.length - sel.length !== 2) throw new Error('se esperaban BEGIN y ROLLBACK');
const cuerpo = sel.map(s => s.trimEnd().replace(/;$/, ''));
if (cuerpo.some(s => !/^SELECT\b/i.test(s.trim()))) throw new Error('solo se admiten SELECT');
const cabecera = [
  '-- HOTFIX COTIZACIONES — VERIFICACION en UNA sola tabla de resultados (SOLO LECTURA).',
  '-- Mismas consultas que HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql (generado por tests/hotfix-cotizaciones/ensayo/generar-verificar-una-tabla.cjs),',
  '-- reunidas en una unica instruccion porque el SQL Editor de Supabase solo muestra el resultado de la ultima. Un solo SELECT: no escribe nada.',
  '-- Cada linea empieza por su categoria; "ERROR|..." indica un incumplimiento. La ultima linea es RESULTADO|INSTALADO o RESULTADO|NO_INSTALADO.'
];
const ctes = cuerpo.map((s, i) => 's' + (i + 1) + ' AS (\n' + s + '\n)').join(',\n');
const unidos = cuerpo.map((s, i) => 'SELECT ' + (i + 1) + ' AS o, * FROM s' + (i + 1)).join('\nUNION ALL\n');
const sql = cabecera.join('\n') + '\nWITH ' + ctes + '\nSELECT linea FROM (\n' + unidos.replace(/SELECT (\d+) AS o, \* FROM (s\d+)/g, 'SELECT $1 AS o, $2.* FROM $2') + '\n) u(o, linea) ORDER BY o, linea;\n';
fs.writeFileSync(path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR_UNA_TABLA.sql'), sql, 'utf8');
console.log('generado: ' + sel.length + ' consultas');
