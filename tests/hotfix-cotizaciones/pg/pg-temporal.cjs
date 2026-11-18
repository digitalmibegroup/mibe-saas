'use strict';
/* PostgreSQL TEMPORAL y local (127.0.0.1, puerto aleatorio, carpeta temporal que se borra
   al terminar). Solo datos ficticios. Nunca se conecta a staging ni a produccion. */
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { spawnSync, spawn } = require('node:child_process');
const BIN = process.env.LACAVA_PG_BIN || 'C:/Users/USUARIO/LaCava-herramientas/pg17-extraido/pgsql/bin';
const exe = n => path.join(BIN, n + (process.platform === 'win32' ? '.exe' : ''));
const RAIZ = path.join(__dirname, '..', '..', '..');
const ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^PG/i.test(k)));
ENV.PGCLIENTENCODING = 'UTF8';

function disponible() { return fs.existsSync(exe('psql')) && fs.existsSync(exe('pg_ctl')) && fs.existsSync(exe('initdb')); }

function iniciar() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lacava-cotconv-'));
  const datos = path.join(tmp, 'd');
  let r = spawnSync(exe('initdb'), ['-D', datos, '-U', 'postgres', '-A', 'trust', '-E', 'UTF8', '--no-locale'], { env: ENV, stdio: 'ignore' });
  if (r.status !== 0) throw new Error('initdb fallo');
  /* Varias suites arrancan su propio PostgreSQL en paralelo: si el puerto ya esta ocupado, se prueba otro. */
  let puerto = null, ultimo = '';
  for (let intento = 0; intento < 12 && !puerto; intento++) {
    const p = String(56000 + ((process.pid * 31 + intento * 977 + Math.floor(Math.random() * 3000)) % 3000));
    r = spawnSync(exe('pg_ctl'), ['start', '-w', '-t', '60', '-D', datos, '-l', path.join(tmp, 'log'), '-o', '-p ' + p + ' -c listen_addresses=127.0.0.1 -c max_connections=40'], { env: ENV, stdio: 'ignore' });
    if (r.status === 0) puerto = p; else ultimo = fs.existsSync(path.join(tmp, 'log')) ? fs.readFileSync(path.join(tmp, 'log'), 'utf8').slice(-400) : '';
  }
  if (!puerto) throw new Error('pg_ctl start fallo: ' + ultimo);
  const args = (db) => ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose', '-h', '127.0.0.1', '-p', puerto, '-U', 'postgres', '-d', db];
  const pg = {
    puerto, tmp,
    /* Ejecuta SQL (como postgres o, con rol, tras SET ROLE). Devuelve {ok, out, err, codigo}. */
    sql(texto, opc) {
      opc = opc || {};
      const pre = (opc.rol ? 'SET ROLE ' + opc.rol + ';\n' : '') + (opc.antes || '');
      const x = spawnSync(exe('psql'), args(opc.db || 'prueba'), { input: '\\set VERBOSITY verbose\n' + pre + texto, encoding: 'utf8', env: ENV, maxBuffer: 1 << 26 });
      const err = (x.stderr || '').trim();
      const m = err.match(/ERROR:\s+([0-9A-Z]{5}):\s*([^\n]*)/);
      return { ok: x.status === 0, out: (x.stdout || '').trim(), err, codigo: m ? m[1] : null, mensaje: m ? m[2] : null };
    },
    /* Igual pero asincrono (para concurrencia real entre sesiones). */
    sqlAsync(texto, opc) {
      opc = opc || {};
      const pre = (opc.rol ? 'SET ROLE ' + opc.rol + ';\n' : '') + (opc.antes || '');
      return new Promise((res) => {
        const p = spawn(exe('psql'), args(opc.db || 'prueba'), { env: ENV });
        let out = '', err = '';
        p.stdout.on('data', d => out += d); p.stderr.on('data', d => err += d);
        p.on('close', (status) => { const m = err.match(/ERROR:\s+([0-9A-Z]{5}):\s*([^\n]*)/); res({ ok: status === 0, out: out.trim(), err: err.trim(), codigo: m ? m[1] : null, mensaje: m ? m[2] : null }); });
        p.stdin.end('\\set VERBOSITY verbose\n' + pre + texto);
      });
    },
    /* Aplica un archivo SQL. Por defecto como supa_postgres: administrador SIN superusuario (CREATEROLE) que posee las
       tablas, igual que el rol postgres de Supabase. rol=null lo ejecuta como superusuario. Devuelve {ok,out,err,codigo,mensaje}. */
    archivoSeguro(ruta, db, rol) {
      const r = rol === undefined ? 'supa_postgres' : rol;
      const a = args(db || 'prueba').concat(r ? ['-c', 'SET ROLE ' + r] : [], ['-f', ruta]);
      const x = spawnSync(exe('psql'), a, { encoding: 'utf8', env: ENV, maxBuffer: 1 << 26 });
      const err = (x.stderr || '').trim(), m = err.match(/ERROR:\s+([0-9A-Z]{5}):\s*([^\n]*)/);
      return { ok: x.status === 0, out: (x.stdout || '').trim(), err, codigo: m ? m[1] : null, mensaje: m ? m[2] : null };
    },
    archivo(ruta, db, rol) {
      const x = pg.archivoSeguro(ruta, db, rol);
      if (!x.ok) throw new Error(path.basename(ruta) + ': ' + x.err);
      return x.out;
    },
    detener() {
      spawnSync(exe('pg_ctl'), ['stop', '-m', 'fast', '-w', '-D', datos], { env: ENV, stdio: 'ignore' });
      try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { /* carpeta temporal */ }
    }
  };
  const roles = pg.sql('CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS; '
    + 'CREATE ROLE supa_postgres NOLOGIN CREATEROLE CREATEDB NOSUPERUSER; GRANT anon, authenticated, service_role TO supa_postgres; '
    + 'CREATE DATABASE prueba OWNER supa_postgres;', { db: 'postgres' });
  if (!roles.ok) throw new Error(roles.err);
  const esq = pg.sql('ALTER SCHEMA public OWNER TO supa_postgres;');
  if (!esq.ok) throw new Error(esq.err);
  return pg;
}
/* Base lista: esquema de produccion minimo + RPC de abonos de produccion + (opcional) la funcion nueva. */
function prepararBase(pg, conFuncion) {
  pg.archivo(path.join(__dirname, 'esquema-produccion-minimo.sql'));
  pg.archivo(path.join(__dirname, 'registrar-abono-produccion.sql'));
  if (conFuncion !== false) pg.archivo(path.join(RAIZ, 'HOTFIX_COT_CONVERSION_ATOMICA.sql'));
}
const lit = v => v == null ? 'NULL' : "'" + String(v).replace(/'/g, "''") + "'";
module.exports = { disponible, iniciar, prepararBase, lit, RAIZ };
