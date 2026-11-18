'use strict';
/* Entrada interactiva para credenciales. En modo oculto NADA de lo escrito o pegado se muestra: readline reescribe la
   linea completa (aviso + texto) al pegar o borrar, asi que el filtro deja pasar SOLO el aviso y los saltos de linea. */
function filtroOculto(pregunta, escribir) {
  return (s) => {
    if (typeof s === 'string' && s.startsWith(pregunta)) escribir(pregunta);   /* solo el aviso, nunca el texto escrito */
    else if (typeof s === 'string' && /^[\r\n]+$/.test(s)) escribir(s);
  };
}
function pedir(pregunta, oculto, recortar) {
  return new Promise((resolve) => {
    const rl = require('node:readline').createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    if (oculto) rl._writeToOutput = filtroOculto(pregunta, (t) => rl.output.write(t));
    rl.question(pregunta, (r) => { rl.close(); if (oculto) process.stdout.write('\n'); resolve(oculto && !recortar ? r : r.trim()); });
  });
}
module.exports = { pedir, filtroOculto };
