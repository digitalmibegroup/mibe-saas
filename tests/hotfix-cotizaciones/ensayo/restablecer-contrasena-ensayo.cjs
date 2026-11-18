'use strict';
/* RESTABLECE SOLO LA CONTRASENA del usuario FICTICIO del ensayo en el staging ca10112ba2, con la API de administracion
   (PUT /auth/v1/admin/users/{uuid}, cuerpo { password }). Conserva UUID, correo y perfil: no toca nada mas.
   Uso:  node restablecer-contrasena-ensayo.cjs --uuid <UUID del perfil activo, confirmado por LEER-PERFIL-ENSAYO-STAGING.ps1>
   Defensas:
     - Solo staging (huella ca10112ba2); rechaza produccion y cualquier otro proyecto.
     - Exige el UUID EXACTO del usuario con perfil activo (confirmado aparte contra la base): no se deduce por conteo.
     - Antes de escribir: el usuario con ese UUID debe existir en Auth y su correo debe terminar en .invalid.
     - Pide la clave administrativa, la clave publica y la nueva contrasena (dos veces) SIN ECO. Nada se escribe en archivos
       ni en registros; no se imprime ninguno de esos valores ni respuestas de la API.
     - Despues verifica el acceso (inicio de sesion con la nueva contrasena y lacava_mi_sesion) sin mostrar credenciales, anula las
       variables y termina el proceso. */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const { validarDestino, normalizarUrl } = require('./servidor-ensayo-staging.cjs');

/* Nucleo (sin entrada interactiva): devuelve un informe SIN credenciales. */
async function restablecer({ url, claveAdmin, clavePublica, nuevaClave, uuid, fetchFn, validarFn }) {
  const f = fetchFn || fetch;
  const mal = (validarFn || validarDestino)(url); if (mal) throw new Error(mal); /* validarFn solo lo usan las pruebas con un Auth falso */
  if (!UUID.test(String(uuid || ''))) throw new Error('El UUID del perfil activo no es valido.');
  uuid = uuid.toLowerCase();
  if (!nuevaClave || nuevaClave.length < 12) throw new Error('La nueva contrasena debe tener al menos 12 caracteres.');
  const adm = { apikey: claveAdmin, Authorization: 'Bearer ' + claveAdmin, 'content-type': 'application/json' };
  /* 1) el usuario con ESE uuid existe y es ficticio (correo .invalid) */
  const g = await f(url + '/auth/v1/admin/users/' + uuid, { headers: adm });
  if (g.status === 404) throw new Error('No existe un usuario de Auth con ese UUID. No se cambio nada.');
  if (!g.ok) throw new Error('No se pudo leer el usuario (HTTP ' + g.status + '). La clave administrativa podria no ser la de este proyecto. No se cambio nada.');
  const antes = await g.json();
  if (String(antes.id || '').toLowerCase() !== uuid) throw new Error('La API devolvio otro usuario. No se cambio nada.');
  if (!/\.invalid$/i.test(String(antes.email || ''))) throw new Error('El correo del usuario NO termina en .invalid: no es el usuario ficticio. No se cambio nada.');
  /* 2) cambia UNICAMENTE la contrasena */
  const p = await f(url + '/auth/v1/admin/users/' + uuid, { method: 'PUT', headers: adm, body: JSON.stringify({ password: nuevaClave }) });
  if (!p.ok) throw new Error('La API rechazo el cambio de contrasena (HTTP ' + p.status + '). No se sabe si cambio; se verifica a continuacion.');
  const despues = await p.json();
  if (String(despues.id || '').toLowerCase() !== uuid || despues.email !== antes.email) throw new Error('El UUID o el correo cambiaron: comprobar de inmediato en el panel.');
  /* 3) verifica el acceso con la nueva contrasena (sin mostrar nada) */
  const li = await f(url + '/auth/v1/token?grant_type=password', { method: 'POST', headers: { apikey: clavePublica, 'content-type': 'application/json' }, body: JSON.stringify({ email: antes.email, password: nuevaClave }) });
  const sesion = li.ok ? await li.json() : null;
  if (!sesion || !sesion.access_token) throw new Error('La nueva contrasena NO permite iniciar sesion (HTTP ' + li.status + ').');
  if (!sesion.user || String(sesion.user.id).toLowerCase() !== uuid) throw new Error('El inicio de sesion devolvio otro usuario.');
  const ms = await f(url + '/rest/v1/rpc/lacava_mi_sesion', { method: 'POST', headers: { apikey: clavePublica, Authorization: 'Bearer ' + sesion.access_token, 'content-type': 'application/json' }, body: '{}' });
  const info = ms.ok ? await ms.json() : null;
  if (!info || !info.licencia) throw new Error('El usuario inicia sesion, pero lacava_mi_sesion no confirma el perfil (HTTP ' + ms.status + ').');
  return { uuid_conservado: true, correo_conservado: true, acceso_verificado: true, perfil: { licencia: info.licencia, rol: info.rol, ventas_habilitadas: info.ventas_habilitadas } };
}

/* ---------- uso interactivo ---------- */
const { pedir } = require('./entrada-oculta.cjs');
async function main() {
  const i = process.argv.indexOf('--uuid'); const uuid = i > 0 ? String(process.argv[i + 1] || '') : '';
  if (!UUID.test(uuid)) { console.error('Falta --uuid <UUID del perfil activo> (lo confirma LEER-PERFIL-ENSAYO-STAGING.ps1). No se hizo nada.'); process.exit(2); }
  console.log('Restablecer SOLO la contrasena del usuario ficticio del ensayo en STAGING (UUID ' + uuid + ').');
  console.log('Los valores que escribas no se muestran, no se guardan en archivos ni en registros, y este proceso termina al acabar.');
  let url = normalizarUrl(await pedir('URL del proyecto de STAGING (https://xxxx.supabase.co): '));
  const mal = validarDestino(url); if (mal) { console.error(mal); process.exit(4); }
  let claveAdmin = await pedir('Clave ADMINISTRATIVA (service_role) de STAGING (no se muestra): ', true);
  let clavePublica = await pedir('Clave PUBLICA (anon) de STAGING (no se muestra): ', true);
  let n1 = await pedir('NUEVA contrasena (no se muestra): ', true);
  let n2 = await pedir('Repite la NUEVA contrasena (no se muestra): ', true);
  if (n1 !== n2) { console.error('Las contrasenas no coinciden. No se hizo nada.'); process.exit(2); }
  const faltas = [];
  if (claveAdmin.trim().length < 20) faltas.push('la clave ADMINISTRATIVA esta vacia o es demasiado corta (menos de 20 caracteres)');
  if (clavePublica.trim().length < 20) faltas.push('la clave PUBLICA esta vacia o es demasiado corta (menos de 20 caracteres)');
  if (n1.length < 12) faltas.push('la NUEVA contrasena tiene menos de 12 caracteres');
  if (faltas.length) { console.error('Datos no validos: ' + faltas.join('; ') + '. No se hizo nada.'); process.exit(2); }
  const frase = await pedir('Para continuar escribe exactamente  RESTABLECER CONTRASENA EN STAGING : ');
  if (frase !== 'RESTABLECER CONTRASENA EN STAGING') { console.error('Confirmacion distinta. No se hizo nada.'); process.exit(4); }
  let codigo = 0;
  try {
    const r = await restablecer({ url, claveAdmin: claveAdmin.trim(), clavePublica: clavePublica.trim(), nuevaClave: n1, uuid });
    console.log('\nContrasena restablecida y acceso verificado.');
    console.log('  UUID conservado: ' + r.uuid_conservado + ' - correo conservado: ' + r.correo_conservado + ' - perfil: licencia "' + r.perfil.licencia + '", rol ' + r.perfil.rol + ', ventas habilitadas: ' + r.perfil.ventas_habilitadas);
  } catch (e) { console.error('\nNO se completo: ' + e.message); codigo = 3; }
  url = claveAdmin = clavePublica = n1 = n2 = null; /* anula los valores y termina el proceso */
  process.exit(codigo);
}
if (require.main === module) main().catch(() => { console.error('Error inesperado. No se muestran detalles para no exponer valores.'); process.exit(3); });
module.exports = { restablecer };
