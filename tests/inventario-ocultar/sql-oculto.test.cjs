'use strict';
/* Pruebas locales del SQL minimo "ocultar productos del Inventario" en un PostgreSQL TEMPORAL (127.0.0.1, datos ficticios; nunca staging ni produccion).
   Reutiliza el esquema de produccion minimo de las pruebas del hotfix (tabla inventario con su politica de anon). */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { disponible, iniciar, prepararBase, RAIZ } = require('../hotfix-cotizaciones/pg/pg-temporal.cjs');

const INSTALAR = path.join(RAIZ, 'INVENTARIO_OCULTAR_PRODUCTOS.sql');
const REVERTIR = path.join(RAIZ, 'INVENTARIO_OCULTAR_PRODUCTOS_REVERTIR.sql');
const VERIFICAR = path.join(RAIZ, 'INVENTARIO_OCULTAR_PRODUCTOS_VERIFICAR.sql');
const SKIP = !disponible() && 'PostgreSQL portable no disponible';
let pg = null;
const q = (t, o) => { const r = pg.sql(t, o); assert.ok(r.ok, r.err); return r.out; };
const verificar = () => pg.archivo(VERIFICAR);

before(() => {
  if (SKIP) return;
  pg = iniciar(); prepararBase(pg, false);
  q("INSERT INTO inventario (id,nombre,categoria,precio_venta,stock,uds_sueltas,uds_empaque,id_licencia) VALUES ('p1','Aguila','Cerveza',3000,0,0,1,'lacava'),('p2','Ron','Licores',80000,5,0,1,'lacava'),('p3','Poker six','Cerveza',20000,0,3,6,'lacava')");
});
after(() => { if (pg) pg.detener(); });

test('antes de instalar: VERIFICAR dice NO_INSTALADO y no hay columna', { skip: SKIP }, () => {
  assert.match(verificar(), /^NO_INSTALADO\|3\|?$/m);
  assert.equal(q("SELECT count(*) FROM information_schema.columns WHERE table_name='inventario' AND column_name='oculto'"), '0');
});

test('instalar: agrega solo oculto boolean NOT NULL DEFAULT false y no toca ningun dato existente', { skip: SKIP }, () => {
  const antes = q("SELECT md5(string_agg(i::text, '|' ORDER BY id)) FROM (SELECT id,nombre,categoria,precio_venta,precio_costo,stock,stock_min,empaque,uds_empaque,uds_sueltas,id_licencia FROM inventario) i");
  const cols0 = q("SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name='inventario'");
  pg.archivo(INSTALAR);
  const cols1 = q("SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name='inventario'");
  assert.equal(cols1, cols0 + ',oculto', 'solo se agrega la columna oculto, al final');
  assert.equal(q("SELECT data_type||'|'||is_nullable||'|'||column_default FROM information_schema.columns WHERE table_name='inventario' AND column_name='oculto'"), 'boolean|NO|false');
  assert.equal(q("SELECT count(*) FROM inventario WHERE oculto = false"), '3', 'todas las filas existentes quedan visibles');
  const despues = q("SELECT md5(string_agg(i::text, '|' ORDER BY id)) FROM (SELECT id,nombre,categoria,precio_venta,precio_costo,stock,stock_min,empaque,uds_empaque,uds_sueltas,id_licencia FROM inventario) i");
  assert.equal(despues, antes, 'ninguna otra columna ni fila cambio');
  assert.match(verificar(), /^INSTALADO\|3\|0$/m);
});

test('es idempotente: ejecutarlo otra vez no falla ni cambia nada', { skip: SKIP }, () => {
  q("UPDATE inventario SET oculto = true WHERE id = 'p1'");
  pg.archivo(INSTALAR);
  assert.equal(q("SELECT oculto FROM inventario WHERE id='p1'"), 't', 'no reinicia las marcas existentes');
  q("UPDATE inventario SET oculto = false WHERE id = 'p1'");
});

test('la aplicacion no necesita cambios para insertar y leer: filas nuevas sin la columna quedan visibles; la politica de anon cubre la marca', { skip: SKIP }, () => {
  /* como anon (la clave que usa la aplicacion): insertar SIN mencionar oculto, ocultar con la condicion de la aplicacion, leer y restaurar */
  q("INSERT INTO inventario (id,nombre,categoria,precio_venta,id_licencia) VALUES ('p4','Nuevo','General',1000,'lacava')", { rol: 'anon' });
  assert.equal(q("SELECT oculto FROM inventario WHERE id='p4'", { rol: 'anon' }), 'f');
  const r = q("UPDATE inventario SET oculto = true WHERE id='p1' AND id_licencia='lacava' AND stock=0 AND uds_sueltas=0 RETURNING id", { rol: 'anon' });
  assert.match(r, /^p1$/m, 'oculta cuando stock y sueltas son 0');
  assert.equal(q("UPDATE inventario SET oculto = true WHERE id='p2' AND id_licencia='lacava' AND stock=0 AND uds_sueltas=0 RETURNING id", { rol: 'anon' }), '', 'con existencias el PATCH condicionado no actualiza nada');
  assert.equal(q("UPDATE inventario SET oculto = true WHERE id='p3' AND id_licencia='lacava' AND stock=0 AND uds_sueltas=0 RETURNING id", { rol: 'anon' }), '', 'con unidades sueltas tampoco');
  assert.equal(q("SELECT count(*) FROM inventario WHERE oculto", { rol: 'anon' }), '1');
  assert.match(verificar(), /^INSTALADO\|4\|1$/m);
  q("UPDATE inventario SET oculto = false WHERE id='p1' AND id_licencia='lacava' RETURNING id", { rol: 'anon' });
  assert.equal(q("SELECT count(*) FROM inventario WHERE oculto"), '0');
});

test('revertir: elimina solo la columna, deja intactos los datos, y se puede volver a instalar', { skip: SKIP }, () => {
  q("UPDATE inventario SET oculto = true WHERE id='p1'");
  const antes = q("SELECT md5(string_agg(i::text, '|' ORDER BY id)) FROM (SELECT id,nombre,categoria,precio_venta,precio_costo,stock,stock_min,empaque,uds_empaque,uds_sueltas,id_licencia FROM inventario) i");
  pg.archivo(REVERTIR);
  assert.equal(q("SELECT count(*) FROM information_schema.columns WHERE table_name='inventario' AND column_name='oculto'"), '0');
  assert.match(verificar(), /^NO_INSTALADO\|4\|?$/m);
  assert.equal(q("SELECT md5(string_agg(i::text, '|' ORDER BY id)) FROM (SELECT id,nombre,categoria,precio_venta,precio_costo,stock,stock_min,empaque,uds_empaque,uds_sueltas,id_licencia FROM inventario) i"), antes, 'los datos no cambian');
  pg.archivo(REVERTIR);                       /* idempotente */
  pg.archivo(INSTALAR);
  assert.match(verificar(), /^INSTALADO\|4\|0$/m, 'reinstalado: todo visible');
});
