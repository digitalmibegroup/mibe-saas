<#
  COMPROBACION DE RECUPERACION DEL HOTFIX EN STAGING (ca10112ba2): REVERTIR -> VERIFICAR -> REINSTALAR LA VARIANTE -> VERIFICAR.
  ESCRIBE en STAGING (jamas contra produccion). Las conversiones quedan INDISPONIBLES entre los pasos 1 y 2 (no uses el dashboard).
  Autorizada por Michel para esta comprobacion. Defensas de los lanzadores de staging (STAGING-COMUN.ps1, que solo se LEE): rechaza
  produccion por su huella, exige el Session pooler, la huella ca10112ba2, el esquema staging_marca, fija el SHA-256 de los SQL y pide una frase.
  Que hace (DOS conexiones; la contrasena la pide PostgreSQL dos veces):
    SESION 1: lee el estado (precheck + captura de ACL/politicas) -> ejecuta REVERTIR (una transaccion; conserva el registro y todos los datos)
              -> lee el estado -> VERIFICAR. El lanzador comprueba: RPC retiradas, rol retirado, registro conservado con las MISMAS operaciones,
              datos y H1 identicos, y que la captura solo difiere en los objetos del hotfix. SI ALGO NO CUMPLE: SE DETIENE (no reinstala).
    SESION 2: instala la VARIANTE de staging (UNA transaccion; anon sin EXECUTE en ningun momento) -> lee el estado -> VERIFICAR.
              Comprueba: registro REUTILIZADO (mismas operaciones), 2 funciones operativas (authenticated si, anon no), sin membresias
              temporales, y que la captura final es IDENTICA a la de antes de empezar.
  No cambia permisos para sortear errores: ante el primer error se detiene y se informa el estado real.
  Evidencia: %USERPROFILE%\LaCava-evidencia-local\hotfix-staging-ca10112ba2\ (nunca se sobrescribe; sin contrasena, host, usuario ni URLs).
  Uso:  powershell -ExecutionPolicy Bypass -File .\RECUPERAR-HOTFIX-EN-STAGING.ps1
  Codigos de salida: 0 todo correcto - 1 Docker - 2 datos o archivos no validos - 3 la reversion FALLO (nada cambio) - 4 sin confirmacion o
    proyecto distinto - 5 revertido pero la comprobacion posterior NO cumple (SE DETUVO; no se reinstalo) - 6 la reinstalacion o su
    verificacion FALLO (estado real en la evidencia)
#>
param(
  [string]$ProyectoEsperado = 'ca10112ba2',
  [string]$Servidor, [string]$Usuario, [string]$Base, [string]$Confirmacion,
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

$Frase = 'REVERTIR Y REINSTALAR HOTFIX EN STAGING'
$Archivos = [ordered]@{
  'HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql'            = '8ca53b6504bb97274808d083f2b5d7847dc1325f7a3d7689b3f934c1c4250a81'
  'HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql'   = '1371c20aacf7749e25680c5278c0afa3d493891d4c179617fd72578eb19ec850'
  'HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql'           = '275c56e9cc6929528aeb83788a32c63818aeb96dbea9e5bc039c39e2fedb890f'
  'PRECHEQUEO_HOTFIX_EN_STAGING.sql'                      = '5917ecc832447f33d5c8bf9a74fbff707b8a72ae25da5c0a421b5c097a1ae28d'
  'ANON_ENSAYO_STAGING_CAPTURA.sql'                       = 'a3ffc3073d25af970cde5b0f40126803684fe86e30f57a16777d292cd5dc48ca'
}
$EncabezadoSql = "\set ON_ERROR_STOP on`n"
Escribir-Titulo 'RECUPERACION DEL HOTFIX en STAGING: revertir, verificar, reinstalar la variante y verificar (ESCRIBE en staging) - La Cava'
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
$sqlRev = $textos['HOTFIX_COT_CONVERSION_ATOMICA_REVERTIR.sql']; $sqlInst = $textos['HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql']
$sqlVer = $textos['HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql']; $sqlPre = $textos['PRECHEQUEO_HOTFIX_EN_STAGING.sql']; $sqlCapt = $textos['ANON_ENSAYO_STAGING_CAPTURA.sql']
foreach ($par in @(@('REVERTIR', $sqlRev), @('INSTALACION', $sqlInst))) {
  if ((([regex]::Matches($par[1], '(?m)^BEGIN;\s*$')).Count -ne 1) -or (([regex]::Matches($par[1], '(?m)^COMMIT;\s*$')).Count -ne 1)) { Fallar 2 ('El SQL ' + $par[0] + ' no es UNA sola transaccion (un BEGIN y un COMMIT). No se ejecuto nada.') }
}
$sinCom = (($sqlInst -split "`n") | Where-Object { $_ -notmatch '^\s*--' }) -join "`n"
if ($sinCom -match '(?im)^\s*GRANT\s+EXECUTE[^;]*\banon\b') { Fallar 2 'La instalacion concede EXECUTE a anon. No se ejecuto nada.' }

Write-Host ''
Write-Host 'Son los datos del proyecto de STAGING (Supabase > Connect > Session pooler). La contrasena la pedira PostgreSQL DOS VECES (no se ve nada al escribirla: escribela y pulsa Enter).'
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
Write-Host ('RECUPERACION en el proyecto de STAGING con huella ' + $huellaProyecto + ': se RETIRAN las RPC de conversion (conservando el registro y los datos) y se REINSTALAN. Las conversiones estaran INDISPONIBLES unos minutos: no uses el dashboard hasta que termine.') -ForegroundColor Yellow
if (-not (Pedir-Confirmacion $Frase $Confirmacion)) { Fallar 4 'DETENIDO: la confirmacion no coincide. No se conecto.' }

function Redactar([string]$t) {
  if (-not $t) { return '' }
  foreach ($x in @($h, $u, $referencia, $conexion)) { if ($x) { $t = $t.Replace($x, '<oculto>') } }
  return ([regex]::Replace($t, '[A-Za-z0-9.-]+\.pooler\.supabase\.com', '<oculto>'))
}
function Ejecutar-Psql([string]$nombre, [string]$sql, [string]$trabajo) {
  [IO.File]::WriteAllText((Join-Path $trabajo ($nombre + '.sql')), $sql, (New-Object System.Text.UTF8Encoding $false))
  $sh = "#!/bin/sh`npsql `"`$CONN`" -X -W -A -t -F '|' -P pager=off -v ON_ERROR_STOP=1 -o /trabajo/$nombre.out -f /trabajo/$nombre.sql 2>/trabajo/$nombre.err`n"
  [IO.File]::WriteAllText((Join-Path $trabajo ($nombre + '.sh')), $sh, (New-Object System.Text.UTF8Encoding $false))
  Remove-Item -LiteralPath (Join-Path $trabajo ($nombre + '.out')), (Join-Path $trabajo ($nombre + '.err')) -Force -ErrorAction SilentlyContinue
  Write-Host '  (se te pedira la contrasena de la base: no se ve nada al escribirla; escribela y pulsa Enter)' -ForegroundColor DarkGray
  $a = @('run', '--rm', '-it', '-e', ('CONN=' + $conexion), '-v', ($trabajo + ':/trabajo'), $script:ImagenPostgres, 'sh', ('/trabajo/' + $nombre + '.sh'))
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
function Secciones([string[]]$lineas) {
  $s = @{}; $actual = $null
  foreach ($x in $lineas) { if ($x -like 'SECCION|*') { $actual = $x.Substring(8); $s[$actual] = @(); continue }; if ($actual) { $s[$actual] += $x } }
  return $s
}
function Valor([string[]]$lineas, [string]$clave) { foreach ($l in $lineas) { if ($l.StartsWith($clave + '|')) { return $l.Substring($clave.Length + 1).Trim() } }; return $null }
function Ordenar-Acl([string]$s) { if ($s -match '^(.*\{)(.*)(\}.*)$') { return ($Matches[1] + ((@($Matches[2].Split(',')) | Sort-Object) -join ',') + $Matches[3]) }; return $s }
function Sin-Ejecutor([string]$s) { if ($s -match '^(.*\{)(.*)(\}.*)$') { return ($Matches[1] + ((@($Matches[2].Split(',') | Where-Object { $_ -and ($_ -notlike 'cotconv_ejecutor=*') }) | Sort-Object) -join ',') + $Matches[3]) }; return $s }
function Normalizar-Revertido([string[]]$capt) { return @($capt | ForEach-Object { Sin-Ejecutor $_ } | Where-Object { (-not (Es-Hotfix $_)) -and ($_ -notmatch '^CAPT\|columna\|.*\|acl=\{\}$') } | Sort-Object) }
function Es-Hotfix([string]$s) { return ($s -match 'cotconv_|convertir_cotizacion_atomica|cotizacion_conversion_info|cotizacion_conversiones') }
function Ops([string[]]$lineas) { foreach ($x in $lineas) { if ($x -match '^REGISTRO\|operaciones=(\d+)') { return $Matches[1] } }; return $null }
function Estable([string[]]$lineas) { return @($lineas | Where-Object { $_ -like 'DATOS|*' -or $_ -like 'H1|*' -or $_ -like 'SECUENCIA|*' }) }
function Escribir-Evidencia([string]$nombre, [string]$texto) {
  $dir = Join-Path $Evidencia ('hotfix-staging-' + $huellaProyecto); New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $ruta = Join-Path $dir ($nombre + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt')
  $fs = [IO.File]::Open($ruta, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
  try { $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($texto); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
  return $ruta
}
$cabecera = @('(sin contrasenas, host, usuario, URLs ni llaves)', ('fecha_local: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')), ('huella_proyecto_staging: ' + $huellaProyecto), ('lanzador_sha256: ' + $hashPropio)) + @($Archivos.Keys | ForEach-Object { 'sha256 ' + $_ + ': ' + $Archivos[$_] })
$leer = $EncabezadoSql + $script:SqlMarcaStaging
$sqlLecturas = { param($etapa) "SELECT 'SECCION|pre_$etapa';`n" + $sqlPre + "`nSELECT 'SECCION|capt_$etapa';`n" + $sqlCapt + "`nSELECT 'SECCION|ver_$etapa';`n" + $sqlVer }

$trabajo = Join-Path ([IO.Path]::GetTempPath()) ('lacava-recuperar-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $trabajo | Out-Null
$codigoSalida = 0; $fallos = @(); $informe = @()
try {
  # ================= SESION 1: leer -> REVERTIR -> leer =================
  Escribir-Titulo 'Sesion 1 de 2: estado previo, REVERSION (una transaccion), estado posterior y VERIFICAR...'
  $sql1 = $leer + (& $sqlLecturas 'antes') + "`nSELECT 'SECCION|revertir';`n" + $sqlRev + "`n" + (& $sqlLecturas 'revertido') + "`nSELECT 'SECCION|fin1';`n"
  $s1 = Ejecutar-Psql 'sesion1' $sql1 $trabajo
  $e1 = Secciones $s1.lineas
  $antes = $(if ($e1.ContainsKey('pre_antes')) { $e1['pre_antes'] } else { @() }); $captAntes = $(if ($e1.ContainsKey('capt_antes')) { @($e1['capt_antes'] | Where-Object { $_ -like 'CAPT|*' }) } else { @() })
  $revertidoOk = ($s1.codigo -eq 0 -and $e1.ContainsKey('fin1'))
  if (-not $revertidoOk) {
    $codigoSalida = 3
    Write-Host ('LA REVERSION FALLO (codigo ' + $s1.codigo + '). Es una sola transaccion: no cambio nada. Error de Supabase/PostgreSQL:') -ForegroundColor Red; Write-Host $s1.err
    $informe += @('REVERSION: FALLO (se deshizo todo; el hotfix sigue como estaba)', ('codigo: ' + $s1.codigo), 'error:') + @(($s1.err -split "`n") | ForEach-Object { '  ' + $_.TrimEnd() } | Where-Object { $_.Trim() })
  } else {
    Write-Host 'La reversion termino sin errores (COMMIT).' -ForegroundColor Green
    $post = $e1['pre_revertido']; $captPost = @($e1['capt_revertido'] | Where-Object { $_ -like 'CAPT|*' }); $verPost = $e1['ver_revertido']
    $opsAntes = Valor $antes 'DATOS|cotizacion_conversiones'; $opsDesp = Valor $post 'DATOS|cotizacion_conversiones'
    # --- comprobaciones de la reversion
    if ((Valor $verPost 'RESULTADO') -ne 'NO_INSTALADO') { $fallos += 'el verificador no reporta NO_INSTALADO tras revertir' }
    if (@($verPost | Where-Object { $_ -like 'FUNCION|*' }).Count -ne 0) { $fallos += 'siguen existiendo funciones del hotfix (las RPC no se retiraron)' }
    if ((Valor $post 'ROL|existe_cotconv_ejecutor') -ne 'false') { $fallos += 'el rol cotconv_ejecutor sigue existiendo' }
    if ((Valor $post 'COLISION|politicas_cotconv') -ne '0') { $fallos += ('quedan politicas cotconv_*: ' + (Valor $post 'COLISION|politicas_cotconv')) }
    if ((Ops $verPost) -ne $opsAntes) { $fallos += ('el verificador no ve las mismas operaciones en el registro (antes ' + $opsAntes + ', ahora ' + (Ops $verPost) + ')') }
    if ($opsAntes -ne $opsDesp -or $opsDesp -match 'no existe') { $fallos += ('DATOS cotizacion_conversiones antes=' + $opsAntes + ' despues=' + $opsDesp) }
    foreach ($r in @('anon', 'authenticated')) { $pl = @($verPost | Where-Object { $_ -like ('PRIVILEGIO|' + $r + '|cotizacion_conversiones|*') }); if ($pl.Count -ne 1 -or $pl[0] -ne ('PRIVILEGIO|' + $r + '|cotizacion_conversiones|')) { $fallos += ('el registro conservado NO esta cerrado a ' + $r) } }
    if (@($verPost | Where-Object { $_ -like 'DISPARADOR|*' }).Count -lt 1) { $fallos += 'el registro conservado perdio su disparador de solo-anadir' }
    $dEst = Compare-Object -ReferenceObject (Estable $antes) -DifferenceObject (Estable $post)
    if ($dEst) { $fallos += ('datos, H1 o secuencias cambiaron con la reversion: ' + (@($dEst | ForEach-Object { $_.InputObject }) -join ' ; ')) }
    $a = @(Normalizar-Revertido $captAntes); $p = @(Normalizar-Revertido $captPost)
    if ($a.Count -lt 50 -or $p.Count -lt 50) { $fallos += ('la comparacion de capturas no es valida: lineas comparables ' + $a.Count + ' y ' + $p.Count) }
    $dCap = Compare-Object -ReferenceObject $a -DifferenceObject $p
    if ($dCap) { $fallos += ('H1 y los permisos ajenos al hotfix NO quedaron intactos (' + @($dCap).Count + ' diferencias)') }
    $h1a = @($captAntes | Where-Object { $_ -match '\|h1_' }); $h1p = @($captPost | Where-Object { $_ -match '\|h1_' })
    $informe += @('REVERSION: COMMIT', ('registro_operaciones_antes: ' + $opsAntes), ('registro_operaciones_despues: ' + $opsDesp), ('politicas_h1_antes_despues: ' + $h1a.Count + '/' + $h1p.Count), ('lineas_captura_antes: ' + $captAntes.Count), ('lineas_captura_revertido: ' + $captPost.Count), 'verificador_tras_revertir:') + @($verPost | ForEach-Object { '  ' + $_ }) + @('diferencias_ajenas_al_hotfix: ' + $(if ($dCap) { @($dCap).Count } else { 'ninguna' })) + @($dCap | ForEach-Object { '  ' + $_.SideIndicator + ' ' + $_.InputObject })
    if ($fallos.Count -gt 0) {
      $codigoSalida = 5
      Write-Host ''; Write-Host 'REVERTIDO, PERO LA COMPROBACION POSTERIOR NO CUMPLE. SE DETIENE: NO SE REINSTALA. Las conversiones siguen indisponibles.' -ForegroundColor Red
      $fallos | ForEach-Object { Write-Host ('  - ' + $_) -ForegroundColor Red }
      $informe += @('COMPROBACION POSTERIOR A LA REVERSION: NO CUMPLE (reinstalacion NO ejecutada)') + @($fallos | ForEach-Object { '  - ' + $_ })
    }
  }

  # ================= SESION 2: REINSTALAR la variante -> leer =================
  if ($codigoSalida -eq 0) {
    Escribir-Titulo 'Sesion 2 de 2: REINSTALACION de la variante de staging (una transaccion) y verificacion...'
    $sql2 = $leer + "SELECT 'SECCION|reinstalar';`n" + $sqlInst + "`n" + (& $sqlLecturas 'final') + "`nSELECT 'SECCION|extra';`n" + @'
BEGIN TRANSACTION READ ONLY;
SELECT 'EXTRA|membresias_ejecutor|' || COALESCE((SELECT string_agg(m.member::regrole::text || ':admin=' || m.admin_option || ':inherit=' || m.inherit_option || ':set=' || m.set_option, ',')
  FROM pg_auth_members m WHERE m.roleid = (SELECT oid FROM pg_roles WHERE rolname = 'cotconv_ejecutor')), '(ninguna)');
SELECT 'EXTRA|membresias_temporales_set_o_inherit|' || (SELECT count(*) FROM pg_auth_members m WHERE m.roleid = 'cotconv_ejecutor'::regrole AND (m.set_option OR m.inherit_option));
SELECT 'EXTRA|ejecutor_create_en_public|' || has_schema_privilege('cotconv_ejecutor', 'public', 'CREATE')::text;
SELECT 'EXTRA|funcion_' || p.proname || '|dueno=' || p.proowner::regrole::text || '|anon=' || has_function_privilege('anon', p.oid, 'EXECUTE') || '|authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE') || '|public=' || has_function_privilege('public', p.oid, 'EXECUTE')
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('convertir_cotizacion_atomica', 'cotizacion_conversion_info', 'cotconv_registro_inmutable') ORDER BY p.proname;
SELECT 'EXTRA|politicas_cotconv|' || (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND policyname LIKE 'cotconv\_%');
SELECT 'EXTRA|operaciones_en_registro|' || (SELECT count(*) FROM public.cotizacion_conversiones);
ROLLBACK;
'@ + "`nSELECT 'SECCION|fin2';`n"
    $s2 = Ejecutar-Psql 'sesion2' $sql2 $trabajo
    $e2 = Secciones $s2.lineas
    $instalOk = ($s2.codigo -eq 0 -and $e2.ContainsKey('fin2'))
    $fallos2 = @()
    if (-not $instalOk) {
      $codigoSalida = 6
      Write-Host ('LA REINSTALACION FALLO (codigo ' + $s2.codigo + '). Error de Supabase/PostgreSQL:') -ForegroundColor Red; Write-Host $s2.err
      $informe += @('REINSTALACION: FALLO', ('codigo: ' + $s2.codigo), 'error:') + @(($s2.err -split "`n") | ForEach-Object { '  ' + $_.TrimEnd() } | Where-Object { $_.Trim() }) + @('Estado real: ver la lectura posterior si existe; las conversiones siguen indisponibles.')
    } else {
      Write-Host 'La reinstalacion termino sin errores (COMMIT).' -ForegroundColor Green
      $preF = $e2['pre_final']; $captF = @($e2['capt_final'] | Where-Object { $_ -like 'CAPT|*' }); $verF = $e2['ver_final']; $ex = $e2['extra']
      if ((Valor $verF 'RESULTADO') -ne 'INSTALADO') { $fallos2 += 'el verificador no reporta INSTALADO' }
      if (@($verF | Where-Object { $_ -like 'ERROR|*' }).Count -gt 0) { $fallos2 += 'el verificador reporta lineas ERROR' }
      $fn = @($verF | Where-Object { $_ -like 'FUNCION|*' })
      if ($fn.Count -ne 2) { $fallos2 += ('se esperaban 2 funciones y hay ' + $fn.Count) }
      foreach ($f in $fn) { if ($f -notlike '*|definer=true|dueno=cotconv_ejecutor|*|anon_exec=false|auth_exec=true|public_exec=false') { $fallos2 += ('permisos de funcion no esperados: ' + $f) } }
      if ((Ops $verF) -ne $opsAntes) { $fallos2 += ('el verificador no ve las mismas operaciones (antes ' + $opsAntes + ', ahora ' + (Ops $verF) + ')') }
      if ((Valor $ex 'EXTRA|operaciones_en_registro') -ne $opsAntes) { $fallos2 += ('el registro NO se reutilizo con las mismas operaciones (antes ' + $opsAntes + ', ahora ' + (Valor $ex 'EXTRA|operaciones_en_registro') + ')') }
      if (-not ($s2.err -match 'se reutiliza el registro existente')) { $fallos2 += 'el instalador no aviso que reutilizaba el registro existente' }
      if ((Valor $ex 'EXTRA|membresias_temporales_set_o_inherit') -ne '0') { $fallos2 += ('quedan membresias temporales: ' + (Valor $ex 'EXTRA|membresias_ejecutor')) }
      if ((Valor $ex 'EXTRA|ejecutor_create_en_public') -ne 'false') { $fallos2 += 'el rol ejecutor conserva CREATE en public' }
      if ((Valor $ex 'EXTRA|politicas_cotconv') -ne '15') { $fallos2 += ('politicas cotconv_*: ' + (Valor $ex 'EXTRA|politicas_cotconv') + ' (se esperaban 15)') }
      foreach ($l in @($ex | Where-Object { $_ -like 'EXTRA|funcion_*' })) { if ($l -like 'EXTRA|funcion_convertir*' -or $l -like 'EXTRA|funcion_cotizacion_conversion_info*') { if ($l -notlike '*|anon=false|authenticated=true|public=false') { $fallos2 += ('anon/authenticated/public no esperados: ' + $l) } } elseif ($l -notlike '*|anon=false|authenticated=false|public=false') { $fallos2 += ('la funcion del disparador es ejecutable: ' + $l) } }
      foreach ($r in @('anon', 'authenticated')) { $pl = @($verF | Where-Object { $_ -like ('PRIVILEGIO|' + $r + '|cotizacion_conversiones|*') }); if ($pl.Count -ne 1 -or $pl[0] -ne ('PRIVILEGIO|' + $r + '|cotizacion_conversiones|')) { $fallos2 += ('el registro NO esta cerrado a ' + $r) } }
      $dEst2 = Compare-Object -ReferenceObject (Estable $antes) -DifferenceObject (Estable $preF)
      if ($dEst2) { $fallos2 += ('datos, H1 o secuencias distintos del estado inicial: ' + (@($dEst2 | ForEach-Object { $_.InputObject }) -join ' ; ')) }
      $dFin = Compare-Object -ReferenceObject @($captAntes | ForEach-Object { Ordenar-Acl $_ } | Sort-Object) -DifferenceObject @($captF | ForEach-Object { Ordenar-Acl $_ } | Sort-Object)
      if ($dFin) { $fallos2 += ('la captura final NO es identica a la inicial (' + @($dFin).Count + ' diferencias)') }
      $informe += @('REINSTALACION DE LA VARIANTE: COMMIT', ('registro_reutilizado: operaciones ' + (Valor $ex 'EXTRA|operaciones_en_registro') + ' (antes ' + $opsAntes + ')'), ('aviso_del_instalador_reutiliza_registro: ' + ($s2.err -match 'se reutiliza el registro existente')), 'verificador_final:') + @($verF | ForEach-Object { '  ' + $_ }) + @('extra:') + @($ex | ForEach-Object { '  ' + $_ }) +
        @(('lineas_captura_final: ' + $captF.Count), ('diferencias_final_vs_inicial: ' + $(if ($dFin) { @($dFin).Count } else { 'ninguna (captura IDENTICA)' }))) + @($dFin | ForEach-Object { '  ' + $_.SideIndicator + ' ' + $_.InputObject })
      if ($fallos2.Count -gt 0) {
        $codigoSalida = 6; $fallos = $fallos2
        Write-Host ''; Write-Host 'REINSTALADO, PERO LA VERIFICACION NO CUMPLE (no se cambio ningun permiso para sortearlo):' -ForegroundColor Red
        $fallos2 | ForEach-Object { Write-Host ('  - ' + $_) -ForegroundColor Red }
        $informe += @('VERIFICACION FINAL: NO CUMPLE') + @($fallos2 | ForEach-Object { '  - ' + $_ })
      }
    }
  }
}
finally { if (Test-Path -LiteralPath $trabajo) { Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue } }

$dictamen = switch ($codigoSalida) { 0 { 'RECUPERACION CORRECTA: revertido, verificado, reinstalado y verificado; registro reutilizado; captura final identica a la inicial' } 3 { 'REVERSION FALLIDA: no cambio nada' } 5 { 'REVERTIDO; COMPROBACION POSTERIOR NO CUMPLE; REINSTALACION NO EJECUTADA (conversiones indisponibles)' } default { 'REINSTALACION O VERIFICACION FINAL CON PROBLEMAS (ver arriba)' } }
$texto = (@('EVIDENCIA DE LA COMPROBACION DE RECUPERACION DEL HOTFIX EN STAGING') + $cabecera + @('') + $informe + @('', ('codigo_de_salida: ' + $codigoSalida), ('dictamen: ' + $dictamen), 'contrasena: no registrada (la pidio PostgreSQL)', '')) -join "`n"
$ruta = Escribir-Evidencia 'RECUPERACION' $texto
Write-Host ''; Write-Host $texto; Write-Host ('Evidencia: ' + $ruta)
if ($codigoSalida -eq 0) { Escribir-Titulo 'RECUPERACION CORRECTA.' } else { Write-Host ('SALIDA ' + $codigoSalida + ': ' + $dictamen) -ForegroundColor Red }
exit $codigoSalida
