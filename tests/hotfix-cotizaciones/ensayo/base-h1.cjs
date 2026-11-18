/* Base LOCAL v5 + H1 (PostgreSQL temporal, datos ficticios) reutilizando los archivos de la copia de integracion (SOLO LECTURA).
   Exporta construir() -> { psql, ok, detener, U }. */
'use strict';
const fs = require('fs'), os = require('os'), path = require('path'), net = require('net');
const { spawnSync } = require('child_process');
const INT = process.env.LACAVA_INTEGRACION || 'C:/Users/USUARIO/Proyectos - Claude code/La Cava licorera/mibe-saas-integracion-compras';
const BT = INT + '/pruebas-locales/base-temporal';
const HOT = path.join(__dirname, '..', '..', '..');
const { armarConH1 } = require(BT + '/armar-paquete-instalacion.cjs');
const BIN = 'C:/Users/USUARIO/LaCava-herramientas/pg17-extraido/pgsql/bin';
const exe = n => path.join(BIN, n + '.exe');
const ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^PG/i.test(k))); ENV.PGCLIENTENCODING = 'UTF8';
const leer = f => fs.readFileSync(path.join(BT, f), 'utf8');
const U = { lacava: 'aaaaaaaa-0000-4000-8000-000000000001', sinPerfil: 'bbbbbbbb-0000-4000-8000-000000000002', otra: 'cccccccc-0000-4000-8000-000000000003' };
const puertoLibre = () => new Promise((r, j) => { const s = net.createServer(); s.on('error', j); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => r(p)); }); });
async function construir() {
  const DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'lacava-compat-')), PUERTO = await puertoLibre(), d = path.join(DIR, 'd');
  const args = () => ['-X', '-q', '-t', '-A', '-F', '|', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose', '-h', '127.0.0.1', '-p', String(PUERTO), '-U', 'postgres', '-d', 'lacava_prueba'];
  const prefijo = q => !q ? '' : q === 'anon' ? 'SET ROLE anon;\n' : `SET ROLE authenticated;\nSET "request.jwt.claims" TO '{"sub":"${U[q]}","role":"authenticated"}';\n`;
  function psql(sql, quien, archivo) {
    const a = archivo ? args().concat(['-f', archivo]) : args();
    const r = spawnSync(exe('psql'), a, { input: archivo ? undefined : prefijo(quien) + sql, encoding: 'utf8', env: ENV, maxBuffer: 1 << 26 });
    const m = /ERROR:\s+([0-9A-Z]{5}):\s*([^\n]*)/.exec(r.stderr || '');
    return { ok: r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || '').trim(), codigo: m ? m[1] : null, mensaje: m ? m[2] : null };
  }
  function sqlAsync(sql, opc) {
    const quien = opc && opc.rol; const { spawn } = require('child_process');
    return new Promise(res => { const p = spawn(exe('psql'), args(), { env: ENV }); let o = '', e = ''; p.stdout.on('data', d => o += d); p.stderr.on('data', d => e += d);
      p.on('close', st => { const m = /ERROR:\s+([0-9A-Z]{5}):\s*([^\n]*)/.exec(e); res({ ok: st === 0, out: o.trim(), err: e.trim(), codigo: m ? m[1] : null, mensaje: m ? m[2] : null }); });
      p.stdin.end(prefijo(quien === 'authenticated' ? 'lacava' : quien) + sql); });
  }
  const ok = (sql, q) => { const r = psql(sql, q); if (!r.ok) throw new Error(r.err.slice(0, 1500)); return r.out; };
  spawnSync(exe('initdb'), ['-D', d, '-U', 'postgres', '-A', 'trust', '-E', 'UTF8', '--no-locale'], { env: ENV, stdio: 'ignore' });
  const s = spawnSync(exe('pg_ctl'), ['start', '-w', '-t', '60', '-D', d, '-l', path.join(DIR, 'log'), '-o', `-p ${PUERTO} -c listen_addresses=127.0.0.1 -c fsync=off -c TimeZone=UTC`], { env: ENV, stdio: 'ignore' });
  if (s.status !== 0) throw new Error('no arranco');
  spawnSync(exe('psql'), ['-X', '-q', '-h', '127.0.0.1', '-p', String(PUERTO), '-U', 'postgres', '-d', 'postgres', '-c', 'CREATE DATABASE lacava_prueba'], { env: ENV });
  const detener = () => { spawnSync(exe('pg_ctl'), ['stop', '-m', 'fast', '-w', '-D', d], { env: ENV, stdio: 'ignore' }); try { fs.rmSync(DIR, { recursive: true, force: true }); } catch (e) { /* tmp */ } };
  try {
    ok(`CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN; GRANT USAGE ON SCHEMA public TO anon, authenticated;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated;`);
    for (const f of ['HITO_6.18.15_SANDBOX_SCHEMA.sql', 'HITO_3.6.1_MIGRACION_SUELTAS.sql']) ok(fs.readFileSync(path.join(INT, f), 'utf8'));
    ok(leer('esquema-complemento.sql')); ok(leer('esquema-seguridad-produccion.sql'));
    ok(`INSERT INTO inventario (id, nombre, precio_venta, precio_costo, stock, empaque, uds_empaque, uds_sueltas, id_licencia) VALUES
        ('real-uno','Producto existente 1',60000,40000,10,'unidad',6,2,'lacava'),('real-dos','Producto existente 2',80000,50000,5,'unidad',1,0,'lacava'),('ajeno','Otra licencia',1000,500,50,'unidad',1,0,'otra');
      INSERT INTO clientes_frecuentes (id,nombre,whatsapp,direccion,detalle,id_licencia) VALUES ('11111111-1111-4111-8111-111111111111','Cliente existente','3001112233','Calle 1','Apto 1','lacava');
      INSERT INTO licencias (cliente, activo, plan, id_cliente) VALUES ('Ficticia La Cava', true, 'pro', 'lacava'), ('Ficticia Otra', true, 'pro', 'otra');
      INSERT INTO auth.users (id, email) VALUES ('${U.lacava}','a@ficticio.invalid'), ('${U.sinPerfil}','b@ficticio.invalid'), ('${U.otra}','c@ficticio.invalid');`);
    const PAQ = armarConH1(leer('PAGOS_COMPRAS_BORRADOR.sql'), leer('H1_01_IDENTIDAD_Y_LICENCIA.sql'), leer('H1_02_ACCESO_POR_LICENCIA.sql'));
    const p = psql(PAQ); if (!p.ok) throw new Error('paquete v5+H1: ' + p.err.slice(0, 600));
    ok(`INSERT INTO app.perfiles_usuario (user_id, id_licencia, id_cliente, rol, nombre_visible) VALUES ('${U.lacava}','lacava','lacava','operador_principal','Operador Ficticio'), ('${U.otra}','otra','otra','operador_principal','Otro');`);
  } catch (e) { detener(); throw e; }
  return { psql, sqlAsync, ok, detener, U, HOT, INT, BT, leer };
}
module.exports = { construir };
