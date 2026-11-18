<#
  FASE B DEL ENSAYO DEL HOTFIX DE COTIZACIONES: INSTALAR EN STAGING (ca10112ba2). ESCRIBE EN STAGING. Ver PLAN_ENSAYO_HOTFIX_EN_STAGING.md.
  Autorizada por Michel solo para la fase B: no crea datos de prueba ni ejecuta conversiones. Jamas contra produccion.
  Defensas (las mismas de los lanzadores de staging existentes, de STAGING-COMUN.ps1, que solo se LEE):
    rechaza produccion por su huella SHA-256, exige el Session pooler, exige la huella del proyecto (ca10112ba2), exige
    el esquema staging_marca y la frase INSTALAR HOTFIX EN STAGING, y fija los SHA-256 de los 3 archivos SQL (si cambia
    uno, no ejecuta nada). Exige ademas la evidencia previa del prechequeo (dictamen APTO, misma consulta).
  Que hace:
    1. Sesion de ESCRITURA: ejecuta HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql con parada ante el primer error.
       Ese archivo es UNA sola transaccion (un BEGIN y un COMMIT): crea el rol, la tabla, las politicas y las funciones,
       da EXECUTE solo a authenticated (anon nunca), retira el CREATE y la membresia temporales y verifica; si algo
       falla, se deshace todo. Si Supabase rechaza un paso, se detiene y se muestra el error. NO cambia el dueno a postgres
       ni amplia privilegios para sortearlo.
    2. Sesion de SOLO LECTURA (siempre, tambien si la instalacion fallo): prechequeo + verificador + comprobaciones
       extra, y compara con la linea base (evidencia del prechequeo) para informar el estado REAL y las diferencias.
  Evidencia: carpeta NUEVA %USERPROFILE%\LaCava-evidencia-local\hotfix-staging-<huella>\ (nunca se sobrescribe), sin
  contrasena, host, usuario ni datos de clientes.
  Uso:  powershell -ExecutionPolicy Bypass -File .\INSTALAR-HOTFIX-EN-STAGING.ps1
  Codigos de salida: 0 instalado y verificado - 1 Docker no disponible - 2 datos o archivos no validos - 3 la instalacion
    FALLO (se reporta el estado real; ver la evidencia) - 4 sin confirmacion o proyecto distinto - 5 instalado pero la
    verificacion o la comparacion con la linea base NO es correcta
#>
param(
  [string]$ProyectoEsperado = 'ca10112ba2',
  [string]$Servidor,
  [string]$Usuario,
  [string]$Base,
  [string]$Confirmacion,
  [string]$DockerExe = 'docker',
  [string]$SufijoHost = '.pooler.supabase.com',
  [string]$Comun = 'C:\Users\USUARIO\Proyectos - Claude code\La Cava licorera\mibe-saas-integracion-compras\pruebas-locales\base-temporal\STAGING-COMUN.ps1',
  [string]$Evidencia = (Join-Path $env:USERPROFILE 'LaCava-evidencia-local')
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
if (-not (Test-Path -LiteralPath $Comun -PathType Leaf)) { Write-Host ('Falta STAGING-COMUN.ps1 en: ' + $Comun + '. No se ejecuto nada.') -ForegroundColor Red; exit 2 }
. $Comun

$Frase = 'INSTALAR HOTFIX EN STAGING'
$Archivos = [ordered]@{
  'HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql' = '1371c20aacf7749e25680c5278c0afa3d493891d4c179617fd72578eb19ec850'
  'HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql'         = '275c56e9cc6929528aeb83788a32c63818aeb96dbea9e5bc039c39e2fedb890f'
  'PRECHEQUEO_HOTFIX_EN_STAGING.sql'                    = '5917ecc832447f33d5c8bf9a74fbff707b8a72ae25da5c0a421b5c097a1ae28d'
}
$EncabezadoSql = "\set ON_ERROR_STOP on`n"

Escribir-Titulo 'FASE B: instalar el hotfix de cotizaciones en STAGING (ESCRIBE en staging) - La Cava'
$problema = Probar-Docker $DockerExe
if ($problema) { Fallar 1 $problema }
$textos = @{}
foreach ($nombre in $Archivos.Keys) {
  $ruta = Join-Path $PSScriptRoot $nombre
  if (-not (Test-Path -LiteralPath $ruta -PathType Leaf)) { Fallar 2 ('Falta ' + $nombre + ' junto al lanzador. No se ejecuto nada.') }
  $hashArchivo = (Get-FileHash -LiteralPath $ruta -Algorithm SHA256).Hash.ToLower()
  Write-Host ('SHA-256 de ' + $nombre + ': ' + $hashArchivo)
  if ($hashArchivo -ne $Archivos[$nombre]) { Fallar 2 ('El archivo ' + $nombre + ' NO es el aprobado (su SHA-256 cambio). No se ejecuto nada.') }
  $textos[$nombre] = [IO.File]::ReadAllText($ruta, [Text.Encoding]::UTF8)
}
$hashPropio = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLower()
Write-Host ('SHA-256 de este lanzador: ' + $hashPropio)
$sqlInstalar = $textos['HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql']
if ((([regex]::Matches($sqlInstalar, '(?m)^BEGIN;\s*$')).Count -ne 1) -or (([regex]::Matches($sqlInstalar, '(?m)^COMMIT;\s*$')).Count -ne 1)) { Fallar 2 'La instalacion no es UNA sola transaccion (se esperaba un BEGIN y un COMMIT). No se ejecuto nada.' }
$sinCom = (($sqlInstalar -split "`n") | Where-Object { $_ -notmatch '^\s*--' }) -join "`n"
if ($sinCom -match '(?im)^\s*GRANT\s+EXECUTE[^;]*\banon\b') { Fallar 2 'La instalacion concede EXECUTE a anon. No se ejecuto nada.' }

# Linea base: la evidencia del prechequeo (misma consulta, dictamen APTO)
$dirEv = $null
$archivoBase = $null
$dirCandidata = Join-Path $Evidencia ('hotfix-staging-' + $ProyectoEsperado)
if (Test-Path -LiteralPath $dirCandidata) {
  $archivoBase = Get-ChildItem -LiteralPath $dirCandidata -Filter 'PRECHEQUEO-HOTFIX-*.txt' | Sort-Object Name | Select-Object -Last 1
}
if (-not $archivoBase) { Fallar 2 ('Falta la evidencia del prechequeo (PRECHEQUEO-HOTFIX-*.txt) en ' + $dirCandidata + '. Ejecuta antes COMPROBAR-HOTFIX-EN-STAGING.ps1. No se ejecuto nada.') }
$lineasBase = @(Get-Content -LiteralPath $archivoBase.FullName -Encoding UTF8)
if (-not ($lineasBase | Where-Object { $_ -like ('consulta_sha256: ' + $Archivos['PRECHEQUEO_HOTFIX_EN_STAGING.sql']) })) { Fallar 2 'La evidencia previa no corresponde a la consulta aprobada. No se ejecuto nada.' }
if (-not ($lineasBase | Where-Object { $_ -like 'dictamen: APTO*' })) { Fallar 2 'La evidencia previa no tiene dictamen APTO. No se ejecuto nada.' }
if (-not ($lineasBase | Where-Object { $_ -like ('huella_proyecto_staging: ' + $ProyectoEsperado) })) { Fallar 2 'La evidencia previa es de otro proyecto. No se ejecuto nada.' }
Write-Host ('Linea base: ' + $archivoBase.Name)

Write-Host ''
Write-Host 'Son los datos del proyecto de STAGING (Supabase > Connect > Session pooler). La contrasena la pedira PostgreSQL (no se ve al escribirla; se pide dos veces: escritura y verificacion).'
$h = Pedir-Dato $Servidor 'Servidor (host) del Session pooler de STAGING' '^[A-Za-z0-9.-]{3,255}$' 'aws-0-REGION.pooler.supabase.com'
$u = Pedir-Dato $Usuario 'Usuario del pooler de STAGING' '^[A-Za-z0-9._-]{1,128}$' 'postgres.xxxxxxxxxxxxxxxxxxxx'
$b = Pedir-Dato $Base 'Base de datos' '^[A-Za-z0-9_-]{1,63}$' 'postgres'
$motivo = Probar-Destino $h $u $b $SufijoHost
if ($motivo) { Fallar 2 $motivo }
$huellaProyecto = Huella-Proyecto $u
if ($huellaProyecto -ne $ProyectoEsperado) { Fallar 4 ('DETENIDO: el proyecto tiene huella ' + $huellaProyecto + ' y se esperaba ' + $ProyectoEsperado + '. No se conecto.') }
$conexion = 'host=' + $h + ' port=' + $script:PuertoSessionPooler + ' dbname=' + $b + ' user=' + $u + ' sslmode=require'
$referencia = ($u -replace '^postgres\.', '')

Write-Host ''
Write-Host ('INSTALACION que ESCRIBE en el proyecto de STAGING con huella ' + $huellaProyecto + ': rol cotconv_ejecutor, tabla cotizacion_conversiones, 15 politicas y 2 funciones, en UNA transaccion; EXECUTE solo para authenticated.') -ForegroundColor Yellow
if (-not (Pedir-Confirmacion $Frase $Confirmacion)) { Fallar 4 'DETENIDO: la confirmacion no coincide. No se conecto.' }

function Redactar([string]$t) {
  if (-not $t) { return '' }
  foreach ($x in @($h, $u, $referencia, $conexion)) { if ($x) { $t = $t.Replace($x, '<oculto>') } }
  return ([regex]::Replace($t, '[A-Za-z0-9.-]+\.pooler\.supabase\.com', '<oculto>'))
}
# Sesion de psql contra el proyecto (la contrasena la pide psql, oculta). Los errores y avisos (stderr) se guardan en un archivo y se muestran despues.
function Ejecutar-Psql([string]$nombre, [string]$sql, [string]$trabajo, [bool]$soloLectura) {
  [IO.File]::WriteAllText((Join-Path $trabajo ($nombre + '.sql')), $sql, (New-Object System.Text.UTF8Encoding $false))
  $sh = "#!/bin/sh`npsql `"`$CONN`" -X -W -A -t -F '|' -P pager=off -v ON_ERROR_STOP=1 -o /trabajo/$nombre.out -f /trabajo/$nombre.sql 2>/trabajo/$nombre.err`n"
  [IO.File]::WriteAllText((Join-Path $trabajo ($nombre + '.sh')), $sh, (New-Object System.Text.UTF8Encoding $false))
  Remove-Item -LiteralPath (Join-Path $trabajo ($nombre + '.out')), (Join-Path $trabajo ($nombre + '.err')) -Force -ErrorAction SilentlyContinue
  $a = @('run', '--rm', '-it', '-e', ('CONN=' + $conexion))
  if ($soloLectura) { $a += @('-e', 'PGOPTIONS=-c default_transaction_read_only=on') }
  $a += @('-v', ($trabajo + ':/trabajo'), $script:ImagenPostgres, 'sh', ('/trabajo/' + $nombre + '.sh'))
  $ErrorActionPreference = 'Continue'
  & $DockerExe @a
  $codigo = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  $out = Join-Path $trabajo ($nombre + '.out'); $err = Join-Path $trabajo ($nombre + '.err')
  $lineas = @(); $errTxt = ''
  if (Test-Path -LiteralPath $out) { $lineas = @(Get-Content -LiteralPath $out -Encoding UTF8 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
  if (Test-Path -LiteralPath $err) { $errTxt = Redactar ((Get-Content -LiteralPath $err -Raw -Encoding UTF8)) }
  return @{ codigo = $codigo; lineas = $lineas; err = $errTxt }
}

$sqlExtra = @'
BEGIN TRANSACTION READ ONLY;
SELECT 'EXTRA|rol_ejecutor_existe|' || EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cotconv_ejecutor');
SELECT 'EXTRA|membresias_ejecutor|' || COALESCE((SELECT string_agg(m.member::regrole::text || ':admin=' || m.admin_option || ':inherit=' || m.inherit_option || ':set=' || m.set_option, ',')
  FROM pg_auth_members m WHERE m.roleid = (SELECT oid FROM pg_roles WHERE rolname = 'cotconv_ejecutor')), '(ninguna)');
SELECT 'EXTRA|ejecutor_create_en_public|' || CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cotconv_ejecutor') THEN has_schema_privilege('cotconv_ejecutor', 'public', 'CREATE')::text ELSE '(sin rol)' END;
SELECT 'EXTRA|ejecutor_usage_en_public|' || CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cotconv_ejecutor') THEN has_schema_privilege('cotconv_ejecutor', 'public', 'USAGE')::text ELSE '(sin rol)' END;
SELECT 'EXTRA|funcion_' || p.proname || '|dueno=' || p.proowner::regrole::text || '|acl=' || COALESCE(p.proacl::text, 'null') || '|anon=' || has_function_privilege('anon', p.oid, 'EXECUTE') || '|authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE') || '|public=' || has_function_privilege('public', p.oid, 'EXECUTE') || '|service_role=' || has_function_privilege('service_role', p.oid, 'EXECUTE')
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('convertir_cotizacion_atomica', 'cotizacion_conversion_info', 'cotconv_registro_inmutable') ORDER BY p.proname;
SELECT 'EXTRA|politicas_h1|' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND policyname LIKE 'h1\_%');
SELECT 'EXTRA|anon_ejecuta_alguna_funcion_del_hotfix|' || EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('convertir_cotizacion_atomica', 'cotizacion_conversion_info', 'cotconv_registro_inmutable') AND has_function_privilege('anon', p.oid, 'EXECUTE'));
ROLLBACK;
'@

$trabajo = Join-Path ([IO.Path]::GetTempPath()) ('lacava-hotfix-instalar-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $trabajo | Out-Null
try {
  # ---- 1. INSTALACION (escritura; parada ante el primer error)
  Escribir-Titulo 'Sesion 1 de 2: INSTALANDO en staging (una transaccion; se detiene ante el primer error)...'
  $i = Ejecutar-Psql 'instalar' ($EncabezadoSql + $script:SqlMarcaStaging + "`n" + $sqlInstalar) $trabajo $false
  $instalacionOk = ($i.codigo -eq 0)
  if ($instalacionOk) { Write-Host 'La instalacion termino sin errores (COMMIT).' -ForegroundColor Green }
  else { Write-Host ('LA INSTALACION FALLO (codigo ' + $i.codigo + '). Error de Supabase/PostgreSQL:') -ForegroundColor Red; Write-Host $i.err }

  # ---- 2. ESTADO REAL (solo lectura; siempre)
  Escribir-Titulo 'Sesion 2 de 2: leyendo el estado REAL (solo lectura)...'
  $sqlLeer = $EncabezadoSql + $script:SqlMarcaStaging + "`nSELECT 'SECCION|precheck';`n" + $textos['PRECHEQUEO_HOTFIX_EN_STAGING.sql'] + "`nSELECT 'SECCION|verificar';`n" + $textos['HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql'] + "`nSELECT 'SECCION|extra';`n" + $sqlExtra + "`nSELECT 'SECCION|fin';`n"
  $l = Ejecutar-Psql 'leer' $sqlLeer $trabajo $true
  $sec = @{ precheck = @(); verificar = @(); extra = @() }
  $actual = $null; $finVisto = $false
  foreach ($x in $l.lineas) {
    if ($x -like 'SECCION|*') { $actual = $x.Substring(8); if ($actual -eq 'fin') { $finVisto = $true }; continue }
    if ($actual -and $sec.ContainsKey($actual)) { $sec[$actual] += $x }
  }
  if ($l.codigo -ne 0 -or -not $finVisto) { Write-Host ('AVISO: la lectura del estado no termino (codigo ' + $l.codigo + '). ' + $l.err) -ForegroundColor Red }

  $val = { param($lineas, $clave) Valor-Linea $lineas $clave }
  # Linea base
  $iniB = [array]::IndexOf($lineasBase, 'salida_de_la_consulta:')
  $baseL = @(); if ($iniB -ge 0) { for ($k = $iniB + 1; $k -lt $lineasBase.Count; $k++) { if ($lineasBase[$k] -like 'motivos_que_impiden_instalar:*') { break }; $t = "$($lineasBase[$k])".Trim(); if ($t) { $baseL += $t } } }
  function Normalizar([string]$s) {
    if ($s -match '^(.*\{)(.*)(\}.*)$') { $items = @($Matches[2].Split(',') | Where-Object { $_ -and ($_ -notlike 'cotconv_ejecutor=*') }); return ($Matches[1] + ($items -join ',') + $Matches[3]) }
    return $s
  }
  $prefijos = @('ACL|', 'ESQUEMA|', 'ACL_FUNCION|', 'POLITICA|', 'DISPARADOR|', 'SECUENCIA|', 'H1|', 'DATOS|', 'TABLA|')
  $normNuevo = @($sec.precheck | ForEach-Object { Normalizar $_ })
  $cambios = @(); $nuevas = @()
  foreach ($bl in $baseL) {
    $esDeInteres = $false; foreach ($p in $prefijos) { if ($bl.StartsWith($p)) { $esDeInteres = $true } }
    if (-not $esDeInteres) { continue }
    if ($bl -like '*cotizacion_conversiones*') { continue }
    if ($normNuevo -notcontains (Normalizar $bl)) { $cambios += $bl }
  }
  $baseNorm = @($baseL | ForEach-Object { Normalizar $_ })
  foreach ($nl in $normNuevo) { $de = $false; foreach ($p in $prefijos) { if ($nl.StartsWith($p)) { $de = $true } }; if ($de -and ($baseNorm -notcontains $nl)) { $nuevas += $nl } }

  # Comprobaciones
  $fallos = @()
  if ($instalacionOk) {
    if ((& $val $sec.verificar 'RESULTADO') -ne 'INSTALADO') { $fallos += 'el verificador no reporta INSTALADO' }
    if (@($sec.verificar | Where-Object { $_ -like 'ERROR|*' }).Count -gt 0) { $fallos += 'el verificador reporta lineas ERROR' }
    $fn = @($sec.verificar | Where-Object { $_ -like 'FUNCION|*' })
    if ($fn.Count -ne 2) { $fallos += ('se esperaban 2 funciones y hay ' + $fn.Count) }
    foreach ($f in $fn) { if ($f -notlike '*|definer=true|dueno=cotconv_ejecutor|*|anon_exec=false|auth_exec=true|public_exec=false') { $fallos += ('permisos de funcion no esperados: ' + $f) } }
    foreach ($r in @('anon', 'authenticated')) { $pl = @($sec.verificar | Where-Object { $_ -like ('PRIVILEGIO|' + $r + '|cotizacion_conversiones|*') }); if ($pl.Count -ne 1 -or $pl[0] -ne ('PRIVILEGIO|' + $r + '|cotizacion_conversiones|')) { $fallos += ('el registro NO esta cerrado a ' + $r) } }
    if ((& $val $sec.extra 'EXTRA|anon_ejecuta_alguna_funcion_del_hotfix') -ne 'false') { $fallos += 'anon puede ejecutar una funcion del hotfix' }
    if ((& $val $sec.extra 'EXTRA|ejecutor_create_en_public') -ne 'false') { $fallos += 'el rol ejecutor conserva CREATE en public' }
    $mem = (& $val $sec.extra 'EXTRA|membresias_ejecutor')
    if ($mem -match 'inherit=true|set=true') { $fallos += ('quedo una membresia temporal: ' + $mem) }
    if ((& $val $sec.extra 'EXTRA|rol_ejecutor_existe') -ne 'true') { $fallos += 'el rol ejecutor no existe' }
    if ($cambios.Count -gt 0) { $fallos += ('cambios no esperados respecto de la linea base: ' + $cambios.Count) }
    $polNuevas = @($nuevas | Where-Object { $_ -like 'POLITICA|*|cotconv_*' }).Count
    if ($polNuevas -ne 15) { $fallos += ('politicas nuevas del hotfix: ' + $polNuevas + ' (se esperaban 15)') }
    if ((& $val $sec.precheck 'DATOS|cotizacion_conversiones') -ne '0') { $fallos += 'el registro no esta vacio o no existe' }
    if ($finVisto -eq $false) { $fallos += 'la lectura del estado no termino' }
  }
  $estadoReal = @(
    ('hotfix_instalado: ' + (& $val $sec.precheck 'ESTADO|hotfix_instalado')),
    ('rol_cotconv_ejecutor_existe: ' + (& $val $sec.extra 'EXTRA|rol_ejecutor_existe')),
    ('tabla_registro_existe: ' + $(if ((& $val $sec.precheck 'DATOS|cotizacion_conversiones') -like '(no existe)') { 'false' } else { 'true' })),
    ('funciones_del_hotfix: ' + (& $val $sec.precheck 'COLISION|funciones_hotfix')),
    ('politicas_cotconv: ' + (& $val $sec.precheck 'COLISION|politicas_cotconv')))
  $dictamen = if (-not $instalacionOk) { 'INSTALACION FALLIDA: el estado real esta arriba; si dice hotfix_instalado false, no quedo nada instalado' }
              elseif ($fallos.Count -eq 0) { 'INSTALADO Y VERIFICADO: sin diferencias de permisos ni de datos respecto de la linea base, salvo los objetos del hotfix' }
              else { 'INSTALADO PERO CON PROBLEMAS: ' + ($fallos -join '; ') }

  $dirNuevo = Join-Path $Evidencia ('hotfix-staging-' + $huellaProyecto)
  New-Item -ItemType Directory -Path $dirNuevo -Force | Out-Null
  $ruta = Join-Path $dirNuevo ('INSTALACION-HOTFIX-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt')
  $texto = (@('EVIDENCIA DE LA FASE B (INSTALACION DEL HOTFIX EN STAGING; sin contrasenas, host, usuario, URLs, llaves ni datos de clientes)',
      ('fecha_local: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')), ('huella_proyecto_staging: ' + $huellaProyecto),
      ('lanzador_sha256: ' + $hashPropio)) +
    @($Archivos.Keys | ForEach-Object { 'sha256 ' + $_ + ': ' + $Archivos[$_] }) +
    @(('linea_base: ' + $archivoBase.Name), ('instalacion_codigo_de_salida: ' + $i.codigo), ('instalacion: ' + $(if ($instalacionOk) { 'COMMIT' } else { 'FALLO (se deshizo todo)' })),
      'instalacion_mensajes_y_errores:') + @(($i.err -split "`n") | ForEach-Object { '  ' + $_.TrimEnd() } | Where-Object { $_.Trim() }) +
    @('estado_real:') + @($estadoReal | ForEach-Object { '  ' + $_ }) +
    @(('lectura_codigo_de_salida: ' + $l.codigo), 'verificador:') + @($sec.verificar | ForEach-Object { '  ' + $_ }) +
    @('extra:') + @($sec.extra | ForEach-Object { '  ' + $_ }) +
    @(('cambios_respecto_de_la_linea_base (debe ser ninguno): ' + $(if ($cambios.Count) { '' } else { 'ninguno' }))) + @($cambios | ForEach-Object { '  ' + $_ }) +
    @('lineas_nuevas_respecto_de_la_linea_base:') + @($nuevas | ForEach-Object { '  ' + $_ }) +
    @('datos_de_negocio_tras_la_fase_B:') + @($sec.precheck | Where-Object { $_ -like 'DATOS|*' -or $_ -like 'SECUENCIA|*' } | ForEach-Object { '  ' + $_ }) +
    @(('dictamen: ' + $dictamen), 'cambios_en_staging: solo los de la instalacion de la fase B (sin datos de prueba ni conversiones)', 'contrasena: no registrada (la pidio PostgreSQL)', '')) -join "`n"
  $fs = [IO.File]::Open($ruta, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
  try { $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($texto); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }

  Write-Host ''
  Write-Host $texto
  Write-Host ''
  Write-Host ('Evidencia: ' + $ruta)
  if (-not $instalacionOk) { Escribir-Titulo 'LA INSTALACION FALLO. Estado real arriba. No se cambio el dueno ni se amplio ningun privilegio.'; exit 3 }
  if ($fallos.Count -gt 0) { Escribir-Titulo 'INSTALADO, PERO LA VERIFICACION NO ES CORRECTA. Revisa la evidencia.'; exit 5 }
  Escribir-Titulo 'INSTALADO Y VERIFICADO.'
  exit 0
}
finally { if (Test-Path -LiteralPath $trabajo) { Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue } }
