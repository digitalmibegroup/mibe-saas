'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { filtroOculto } = require('./entrada-oculta.cjs');
test('modo oculto: al pegar o borrar, readline reescribe aviso + texto; solo sale el aviso', () => {
  const sal = []; const f = filtroOculto('Clave (no se muestra): ', t => sal.push(t));
  f('Clave (no se muestra): sb_secret_ABCDEF123456');   /* reescritura completa al pegar */
  f('Clave (no se muestra): ');                          /* aviso inicial */
  f('s'); f('b'); f('_');                                /* teclas sueltas */
  f('\r\n'); f('\n');
  assert.deepEqual(sal, ['Clave (no se muestra): ', 'Clave (no se muestra): ', '\r\n', '\n']);
  assert.ok(!sal.join('').includes('sb_secret'));
});
