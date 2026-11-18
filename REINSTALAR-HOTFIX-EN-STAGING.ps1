<#
  PASO MINIMO PARA RECUPERAR LAS CONVERSIONES EN STAGING (ca10112ba2) DESPUES DE LA REVERSION: reinstalar la variante, SIN repetir la reversion.
  Jamas contra produccion. Por defecto es de SOLO LECTURA: lee el estado, lo compara con la captura de ANTES de la reversion y lo evalua.
  Con -Reinstalar (y su frase) ademas REINSTALA la variante de staging en UNA transaccion (anon sin EXECUTE en ningun momento), la verifica y
  compara. No cambia permisos para sortear errores: ante el primer fallo se detiene.
  Linea base: la ultima captura ANON-ANTES-*.txt (167 lineas, tomada con el hotfix instalado y tras restaurar el acceso anon temporal) y el
  numero de operaciones del ultimo RECUPERACION-*.txt ('registro_operaciones_antes'), ambos en la carpeta de evidencia. Se puede forzar con
  -Operaciones N y -LineaBase <archivo>.
  Defensas: STAGING-COMUN.ps1 (solo se LEE): rechaza produccion por su huella, exige Session pooler, huella ca10112ba2, esquema staging_marca,
  SHA-256 fijo de los SQL y una frase. La contrasena la pide PostgreSQL (una vez en lectura; una segunda vez si reinstalas).
  Uso:   powershell -ExecutionPolicy Bypass -File .\REINSTALAR-HOTFIX-EN-STAGING.ps1                (solo lectura)
         powershell -ExecutionPolicy Bypass -File .\REINSTALAR-HOTFIX-EN-STAGING.ps1 -Reinstalar    (lee, evalua y reinstala si todo cumple)
  Codigos de salida: 0 correcto - 1 Docker - 2 datos o archivos no validos - 4 sin confirmacion o proyecto distinto - 5 el estado previo NO
    cumple (no se reinstalo) - 6 la reinstalacion o su verificacion FALLO
#>
param(
  [switch]$Reinstalar,
  [string]$ProyectoEsperado = 'ca10112ba2',
  [string]$Servidor, [string]$Usuario, [string]$Base, [string]$Confirmacion,
  [int]$Operaciones = -1, [string]$LineaBase,
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

$FraseLectura = 'LEER ESTADO DEL HOTFIX EN STAGING'; $FraseInstalar = 'REINSTALAR HOTFIX EN STAGING'
$Archivos = [ordered]@{
  'HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql' = '1371c20aacf7749e25680c5278c0afa3d493891d4c179617fd72578eb19ec850'
  'HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql'         = '275c56e9cc6929528aeb83788a32c63818aeb96dbea9e5bc039c39e2fedb890f'
  'PRECHEQUEO_HOTFIX_EN_STAGING.sql'                    = '5917ecc832447f33d5c8bf9a74fbff707b8a72ae25da5c0a421b5c097a1ae28d'
  'ANON_ENSAYO_STAGING_CAPTURA.sql'                     = 'a3ffc3073d25af970cde5b0f40126803684fe86e30f57a16777d292cd5dc48ca'
}
$EncabezadoSql = "\set ON_ERROR_STOP on`n"
Escribir-Titulo ($(if ($Reinstalar) { 'REINSTALAR el hotfix en STAGING (lee, evalua y reinstala; ESCRIBE en staging)' } else { 'Estado del hotfix en STAGING (SOLO LECTURA; no reinstala)' }) + ' - La Cava')
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
$sqlInst = $textos['HOTFIX_COT_CONVERSION_ATOMICA_ENSAYO_STAGING_H1.sql']; $sqlVer = $textos['HOTFIX_COT_CONVERSION_ATOMICA_VERIFICAR.sql']; $sqlPre = $textos['PRECHEQUEO_HOTFIX_EN_STAGING.sql']; $sqlCapt = $textos['ANON_ENSAYO_STAGING_CAPTURA.sql']
if ((([regex]::Matches($sqlInst, '(?m)^BEGIN;\s*$')).Count -ne 1) -or (([regex]::Matches($sqlInst, '(?m)^COMMIT;\s*$')).Count -ne 1)) { Fallar 2 'La instalacion no es UNA sola transaccion. No se ejecuto nada.' }
$sinCom = (($sqlInst -split "`n") | Where-Object { $_ -notmatch '^\s*--' }) -join "`n"
if ($sinCom -match '(?im)^\s*GRANT\s+EXECUTE[^;]*\banon\b') { Fallar 2 'La instalacion concede EXECUTE a anon. No se ejecuto nada.' }

# ---- linea base (evidencia previa)
$dirEv = Join-Path $Evidencia ('hotfix-staging-' + $ProyectoEsperado)
if (-not $LineaBase) { $f = Get-ChildItem -LiteralPath $dirEv -Filter 'ANON-ANTES-*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1; if ($f) { $LineaBase = $f.FullName } }
if (-not $LineaBase -or -not (Test-Path -LiteralPath $LineaBase)) { Fallar 2 ('Falta la captura base ANON-ANTES-*.txt en ' + $dirEv + '. No se ejecuto nada.') }
$captBase = @(Get-Content -LiteralPath $LineaBase -Encoding UTF8 | ForEach-Object { "$_".Trim() } | Where-Object { $_ -like 'CAPT|*' })
if ($captBase.Count -lt 100) { Fallar 2 ('La captura base tiene solo ' + $captBase.Count + ' lineas. No se ejecuto nada.') }
if ($Operaciones -lt 0) {
  $r = Get-ChildItem -LiteralPath $dirEv -Filter 'RECUPERACION-*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
  if ($r) { $l = Get-Content -LiteralPath $r.FullName -Encoding UTF8 | Where-Object { $_ -like 'registro_operaciones_antes: *' } | Select-Object -First 1; if ($l) { $Operaciones = [int]$l.Substring(28).Trim() } }
}
if ($Operaciones -lt 0) { Fallar 2 'No se pudo saber cuantas operaciones tenia el registro (RECUPERACION-*.txt). Usa -Operaciones N. No se ejecuto nada.' }
Write-Host ('Linea base: ' + [IO.Path]::GetFileName($LineaBase) + ' (' + $captBase.Count + ' lineas); operaciones esperadas en el registro: ' + $Operaciones)

Write-Host ''
Write-Host 'Son los datos del proyecto de STAGING (Supabase > Connect > Session pooler). La contrasena la pedira PostgreSQL (no se ve al escribirla).'
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
if ($Reinstalar) { Write-Host ('REINSTALACION que ESCRIBE en STAGING (huella ' + $huellaProyecto + '): se reinstala la variante del hotfix (una transaccion; anon sin EXECUTE) si el estado previo cumple. NO se repite la reversion.') -ForegroundColor Yellow }
else { Write-Host ('LECTURA de SOLO LECTURA sobre STAGING (huella ' + $huellaProyecto + '). No escribe nada.') -ForegroundColor Yellow }
$frase = $(if ($Reinstalar) { $FraseInstalar } else { $FraseLectura })
if (-not (Pedir-Confirmacion $frase $Confirmacion)) { Fallar 4 'DETENIDO: la confirmacion no coincide. No se conecto.' }

function Redactar([string]$t) {
  if (-not $t) { return '' }
  foreach ($x in @($h, $u, $referencia, $conexion)) { if ($x) { $t = $t.Replace($x, '<oculto>') } }
  return ([regex]::Replace($t, '[A-Za-z0-9.-]+\.pooler\.supabase\.com', '<oculto>'))
}
function Ejecutar-Psql([string]$nombre, [string]$sql, [string]$trabajo, [bool]$soloLectura) {
  [IO.File]::WriteAllText((Join-Path $trabajo ($nombre + '.sql')), $sql, (New-Object System.Text.UTF8Encoding $false))
  $sh = "#!/bin/sh`npsql `"`$CONN`" -X -W -A -t -F '|' -P pager=off -v ON_ERROR_STOP=1 -o /trabajo/$nombre.out -f /trabajo/$nombre.sql 2>/trabajo/$nombre.err`n"
  [IO.File]::WriteAllText((Join-Path $trabajo ($nombre + '.sh')), $sh, (New-Object System.Text.UTF8Encoding $false))
  Remove-Item -LiteralPath (Join-Path $trabajo ($nombre + '.out')), (Join-Path $trabajo ($nombre + '.err')) -Force -ErrorAction SilentlyContinue
  Write-Host '  (se te pedira la contrasena de la base: no se ve nada al escribirla; escribela y pulsa Enter)' -ForegroundColor DarkGray
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
function Secciones([string[]]$lineas) { $s = @{}; $actual = $null; foreach ($x in $lineas) { if ($x -like 'SECCION|*') { $actual = $x.Substring(8); $s[$actual] = @(); continue }; if ($actual) { $s[$actual] += $x } }; return $s }
function Valor([string[]]$lineas, [string]$clave) { foreach ($l in $lineas) { if ($l.StartsWith($clave + '|')) { return $l.Substring($clave.Length + 1).Trim() } }; return $null }
function Ops([string[]]$lineas) { foreach ($x in $lineas) { if ($x -match '^REGISTRO\|operaciones=(\d+)') { return $Matches[1] } }; return $null }
function Ordenar-Acl([string]$s) { if ($s -match '^(.*\{)(.*)(\}.*)$') { return ($Matches[1] + ((@($Matches[2].Split(',')) | Sort-Object) -join ',') + $Matches[3]) }; return $s }
function Sin-Ejecutor([string]$s) { if ($s -match '^(.*\{)(.*)(\}.*)$') { return ($Matches[1] + ((@($Matches[2].Split(',') | Where-Object { $_ -and ($_ -notlike 'cotconv_ejecutor=*') }) | Sort-Object) -join ',') + $Matches[3]) }; return $s }
function Es-Hotfix([string]$s) { return ($s -match 'cotconv_|convertir_cotizacion_atomica|cotizacion_conversion_info|cotizacion_conversiones') }
function Normalizar-Revertido([string[]]$capt) { return @($capt | ForEach-Object { Sin-Ejecutor $_ } | Where-Object { (-not (Es-Hotfix $_)) -and ($_ -notmatch '^CAPT\|columna\|.*\|acl=\{\}$') } | Sort-Object) }
function Estable([string[]]$lineas) { return @($lineas | Where-Object { $_ -like 'DATOS|*' -or $_ -like 'H1|*' -or $_ -like 'SECUENCIA|*' }) }
function Escribir-Evidencia([string]$nombre, [string]$texto) {
  $dir = Join-Path $Evidencia ('hotfix-staging-' + $huellaProyecto); New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $ruta = Join-Path $dir ($nombre + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt')
  $fs = [IO.File]::Open($ruta, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
  try { $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($texto); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
  return $ruta
}
$cabecera = @('(sin contrasenas, host, usuario, URLs ni llaves)', ('fecha_local: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')), ('huella_proyecto_staging: ' + $huellaProyecto), ('lanzador_sha256: ' + $hashPropio), ('modo: ' + $(if ($Reinstalar) { 'reinstalar' } else { 'solo lectura' })), ('linea_base: ' + [IO.Path]::GetFileName($LineaBase) + ' (' + $captBase.Count + ' lineas)'), ('operaciones_esperadas: ' + $Operaciones)) + @($Archivos.Keys | ForEach-Object { 'sha256 ' + $_ + ': ' + $Archivos[$_] })
$leer = $EncabezadoSql + $script:SqlMarcaStaging
$lecturas = { param($etapa) "SELECT 'SECCION|pre_$etapa';`n" + $sqlPre + "`nSELECT 'SECCION|capt_$etapa';`n" + $sqlCapt + "`nSELECT 'SECCION|ver_$etapa';`n" + $sqlVer }

$trabajo = Join-Path ([IO.Path]::GetTempPath()) ('lacava-reinstalar-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $trabajo | Out-Null
$codigoSalida = 0; $informe = @(); $fallosA = @(); $fallosB = @()
try {
  # ================= A: LECTURA (solo lectura) y evaluacion del estado revertido =================
  Escribir-Titulo 'Lectura del estado (sesion de solo lectura)...'
  $sA = Ejecutar-Psql 'lectura' ($leer + (& $lecturas 'a') + "`nSELECT 'SECCION|finA';`n") $trabajo $true
  $eA = Secciones $sA.lineas
  if ($sA.codigo -ne 0 -or -not $eA.ContainsKey('finA')) {
    $codigoSalida = 5; Write-Host ('LA LECTURA NO TERMINO (codigo ' + $sA.codigo + '): ' + $sA.err) -ForegroundColor Red
    $informe += @('LECTURA: NO TERMINO', ('codigo: ' + $sA.codigo), $sA.err)
  } else {
    $preA = $eA['pre_a']; $captA = @($eA['capt_a'] | Where-Object { $_ -like 'CAPT|*' }); $verA = $eA['ver_a']
    if ((Valor $verA 'RESULTADO') -ne 'NO_INSTALADO') { $fallosA += ('el verificador no reporta NO_INSTALADO (reporta ' + (Valor $verA 'RESULTADO') + ')') }
    if (@($verA | Where-Object { $_ -like 'FUNCION|*' }).Count -ne 0) { $fallosA += 'hay funciones del hotfix instaladas' }
    if ((Valor $preA 'ROL|existe_cotconv_ejecutor') -ne 'false') { $fallosA += 'el rol cotconv_ejecutor existe' }
    if ((Valor $preA 'COLISION|politicas_cotconv') -ne '0') { $fallosA += ('hay politicas cotconv_*: ' + (Valor $preA 'COLISION|politicas_cotconv')) }
    if ((Ops $verA) -ne [string]$Operaciones) { $fallosA += ('operaciones en el registro: ' + (Ops $verA) + ' (se esperaban ' + $Operaciones + ')') }
    if ((Valor $preA 'DATOS|cotizacion_conversiones') -ne [string]$Operaciones) { $fallosA += ('DATOS cotizacion_conversiones: ' + (Valor $preA 'DATOS|cotizacion_conversiones')) }
    foreach ($r in @('anon', 'authenticated')) { $pl = @($verA | Where-Object { $_ -like ('PRIVILEGIO|' + $r + '|cotizacion_conversiones|*') }); if ($pl.Count -ne 1 -or $pl[0] -ne ('PRIVILEGIO|' + $r + '|cotizacion_conversiones|')) { $fallosA += ('el registro NO esta cerrado a ' + $r) } }
    if (@($verA | Where-Object { $_ -like 'DISPARADOR|*' }).Count -lt 2) { $fallosA += 'el registro no conserva sus 2 disparadores de solo-anadir' }
    $nb = Normalizar-Revertido $captBase; $na = Normalizar-Revertido $captA
    if ($nb.Count -lt 100 -or $na.Count -lt 100) { $fallosA += ('comparacion no valida: lineas comparables base ' + $nb.Count + ', actual ' + $na.Count) }
    $dif = Compare-Object -ReferenceObject $nb -DifferenceObject $na
    if ($dif) { $fallosA += ('H1 y permisos ajenos al hotfix DIFIEREN de la captura base (' + @($dif).Count + ' diferencias)') }
    $informe += @('ESTADO LEIDO (solo lectura)', ('operaciones_en_registro: ' + (Ops $verA)), ('politicas_h1_base_actual: ' + @($captBase | Where-Object { $_ -match '\|h1_' }).Count + '/' + @($captA | Where-Object { $_ -match '\|h1_' }).Count), ('lineas_captura_base_actual: ' + $captBase.Count + '/' + $captA.Count), ('lineas_comparables_base_actual: ' + $nb.Count + '/' + $na.Count), ('diferencias_ajenas_al_hotfix: ' + $(if ($dif) { @($dif).Count } else { 'ninguna' }))) + @($dif | ForEach-Object { '  ' + $_.SideIndicator + ' ' + $_.InputObject }) +
      @('verificador:') + @($verA | ForEach-Object { '  ' + $_ }) + @('datos_h1_secuencias:') + @(Estable $preA | ForEach-Object { '  ' + $_ }) + @('captura_actual:') + @($captA | ForEach-Object { '  ' + $_ })
    if ($fallosA.Count -gt 0) {
      $codigoSalida = 5; Write-Host ''; Write-Host 'EL ESTADO PREVIO NO CUMPLE (no se reinstala):' -ForegroundColor Red; $fallosA | ForEach-Object { Write-Host ('  - ' + $_) -ForegroundColor Red }
      $informe += @('ESTADO PREVIO: NO CUMPLE') + @($fallosA | ForEach-Object { '  - ' + $_ })
    } else { Write-Host 'El estado revertido es el esperado: sin hotfix, registro con sus operaciones, H1 y permisos identicos a la captura base.' -ForegroundColor Green; $informe += 'ESTADO PREVIO: CUMPLE' }
  }

  # ================= B: REINSTALAR (solo con -Reinstalar y estado previo correcto) =================
  if ($codigoSalida -eq 0 -and $Reinstalar) {
    Escribir-Titulo 'REINSTALANDO la variante de staging (una transaccion) y verificando...'
    $sqlB = $leer + "SELECT 'SECCION|reinstalar';`n" + $sqlInst + "`n" + (& $lecturas 'final') + "`nSELECT 'SECCION|extra';`n" + @'
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
'@ + "`nSELECT 'SECCION|finB';`n"
    $sB = Ejecutar-Psql 'reinstalar' $sqlB $trabajo $false
    $eB = Secciones $sB.lineas
    if ($sB.codigo -ne 0 -or -not $eB.ContainsKey('finB')) {
      $codigoSalida = 6; Write-Host ('LA REINSTALACION FALLO (codigo ' + $sB.codigo + '). Error de Supabase/PostgreSQL:') -ForegroundColor Red; Write-Host $sB.err
      $informe += @('REINSTALACION: FALLO (transaccion deshecha; las conversiones siguen indisponibles)', ('codigo: ' + $sB.codigo), 'error:') + @(($sB.err -split "`n") | ForEach-Object { '  ' + $_.TrimEnd() } | Where-Object { $_.Trim() })
    } else {
      Write-Host 'La reinstalacion termino sin errores (COMMIT).' -ForegroundColor Green
      $preF = $eB['pre_final']; $captF = @($eB['capt_final'] | Where-Object { $_ -like 'CAPT|*' }); $verF = $eB['ver_final']; $ex = $eB['extra']
      if ((Valor $verF 'RESULTADO') -ne 'INSTALADO') { $fallosB += 'el verificador no reporta INSTALADO' }
      if (@($verF | Where-Object { $_ -like 'ERROR|*' }).Count -gt 0) { $fallosB += 'el verificador reporta lineas ERROR' }
      $fn = @($verF | Where-Object { $_ -like 'FUNCION|*' }); if ($fn.Count -ne 2) { $fallosB += ('se esperaban 2 funciones y hay ' + $fn.Count) }
      foreach ($f in $fn) { if ($f -notlike '*|definer=true|dueno=cotconv_ejecutor|*|anon_exec=false|auth_exec=true|public_exec=false') { $fallosB += ('permisos de funcion no esperados: ' + $f) } }
      if ((Ops $verF) -ne [string]$Operaciones) { $fallosB += ('el verificador ve ' + (Ops $verF) + ' operaciones (esperadas ' + $Operaciones + ')') }
      if ((Valor $ex 'EXTRA|operaciones_en_registro') -ne [string]$Operaciones) { $fallosB += ('el registro NO se reutilizo con las mismas operaciones: ' + (Valor $ex 'EXTRA|operaciones_en_registro')) }
      if (-not ($sB.err -match 'se reutiliza el registro existente')) { $fallosB += 'el instalador no aviso que reutilizaba el registro existente' }
      if ((Valor $ex 'EXTRA|membresias_temporales_set_o_inherit') -ne '0') { $fallosB += ('quedan membresias temporales: ' + (Valor $ex 'EXTRA|membresias_ejecutor')) }
      if ((Valor $ex 'EXTRA|ejecutor_create_en_public') -ne 'false') { $fallosB += 'el rol ejecutor conserva CREATE en public' }
      if ((Valor $ex 'EXTRA|politicas_cotconv') -ne '15') { $fallosB += ('politicas cotconv_*: ' + (Valor $ex 'EXTRA|politicas_cotconv') + ' (se esperaban 15)') }
      foreach ($l in @($ex | Where-Object { $_ -like 'EXTRA|funcion_*' })) { if ($l -like 'EXTRA|funcion_convertir*' -or $l -like 'EXTRA|funcion_cotizacion_conversion_info*') { if ($l -notlike '*|anon=false|authenticated=true|public=false') { $fallosB += ('anon/authenticated/public no esperados: ' + $l) } } elseif ($l -notlike '*|anon=false|authenticated=false|public=false') { $fallosB += ('la funcion del disparador es ejecutable: ' + $l) } }
      foreach ($r in @('anon', 'authenticated')) { $pl = @($verF | Where-Object { $_ -like ('PRIVILEGIO|' + $r + '|cotizacion_conversiones|*') }); if ($pl.Count -ne 1 -or $pl[0] -ne ('PRIVILEGIO|' + $r + '|cotizacion_conversiones|')) { $fallosB += ('el registro NO esta cerrado a ' + $r) } }
      $dEst = Compare-Object -ReferenceObject (Estable $preA) -DifferenceObject (Estable $preF)
      if ($dEst) { $fallosB += ('datos, H1 o secuencias distintos de los leidos antes de reinstalar: ' + (@($dEst | ForEach-Object { $_.InputObject }) -join ' ; ')) }
      $dFin = Compare-Object -ReferenceObject @($captBase | ForEach-Object { Ordenar-Acl $_ } | Sort-Object) -DifferenceObject @($captF | ForEach-Object { Ordenar-Acl $_ } | Sort-Object)
      if ($captF.Count -lt 100) { $fallosB += 'captura final no valida' }
      if ($dFin) { $fallosB += ('la captura final NO es identica a la base (' + @($dFin).Count + ' diferencias)') }
      $informe += @('REINSTALACION DE LA VARIANTE: COMMIT', ('aviso_del_instalador_reutiliza_registro: ' + ($sB.err -match 'se reutiliza el registro existente')), 'verificador_final:') + @($verF | ForEach-Object { '  ' + $_ }) + @('extra:') + @($ex | ForEach-Object { '  ' + $_ }) + @(('lineas_captura_final: ' + $captF.Count), ('diferencias_final_vs_base: ' + $(if ($dFin) { @($dFin).Count } else { 'ninguna (captura IDENTICA a la base)' }))) + @($dFin | ForEach-Object { '  ' + $_.SideIndicator + ' ' + $_.InputObject })
      if ($fallosB.Count -gt 0) { $codigoSalida = 6; Write-Host ''; Write-Host 'REINSTALADO, PERO LA VERIFICACION NO CUMPLE (no se cambio ningun permiso para sortearlo):' -ForegroundColor Red; $fallosB | ForEach-Object { Write-Host ('  - ' + $_) -ForegroundColor Red }; $informe += @('VERIFICACION FINAL: NO CUMPLE') + @($fallosB | ForEach-Object { '  - ' + $_ }) }
    }
  }
}
finally { if (Test-Path -LiteralPath $trabajo) { Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue } }

$dictamen = switch ($codigoSalida) {
  0 { if ($Reinstalar) { 'REINSTALADO Y VERIFICADO: registro reutilizado, funciones operativas, sin membresias temporales, captura final identica a la base' } else { 'LECTURA: el estado revertido es el esperado; listo para reinstalar con -Reinstalar' } }
  5 { 'EL ESTADO PREVIO NO CUMPLE: no se reinstalo (conversiones indisponibles)' }
  default { 'REINSTALACION O VERIFICACION FINAL CON PROBLEMAS (ver arriba)' } }
$texto = (@('EVIDENCIA ' + $(if ($Reinstalar) { 'DE LA REINSTALACION' } else { 'DE LA LECTURA DEL ESTADO' }) + ' DEL HOTFIX EN STAGING') + $cabecera + @('') + $informe + @('', ('codigo_de_salida: ' + $codigoSalida), ('dictamen: ' + $dictamen), 'contrasena: no registrada (la pidio PostgreSQL)', '')) -join "`n"
$ruta = Escribir-Evidencia $(if ($Reinstalar) { 'REINSTALACION' } else { 'REINSTALAR-LECTURA' }) $texto
Write-Host ''; Write-Host $texto; Write-Host ('Evidencia: ' + $ruta)
if ($codigoSalida -eq 0) { Escribir-Titulo $dictamen } else { Write-Host ('SALIDA ' + $codigoSalida + ': ' + $dictamen) -ForegroundColor Red }
exit $codigoSalida
