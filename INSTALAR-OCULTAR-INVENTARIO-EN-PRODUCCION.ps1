<#
  OCULTAR PRODUCTOS EN INVENTARIO - PRODUCCION: VERIFICAR / INSTALAR la columna inventario.oculto. SOLO CON LA AUTORIZACION EXPRESA DE MICHEL.
  Gemelo del lanzador de staging (ENSAYO-OCULTAR-INVENTARIO-EN-STAGING.ps1) con la guarda INVERTIDA: solo acepta el proyecto de PRODUCCION
  (huella SHA-256 cea2aa59...) y rechaza staging (ca10112ba2). Exige el Session pooler, que NO exista el esquema staging_marca, una frase por accion
  y fija el SHA-256 de los archivos SQL (si cambia uno, no ejecuta nada). Solo LEE STAGING-COMUN.ps1 (funciones auxiliares).
  Acciones:
    Verificar (por defecto, SOLO LECTURA): foto de inventario (datos sin la columna, permisos, politicas, disparadores) + verificador. No escribe nada.
    Instalar  (ESCRIBE): foto previa; exige que la columna NO exista y que el usuario sea dueno de la tabla; UNA transaccion con lock_timeout de 5 s que
              ejecuta SOLO INVENTARIO_OCULTAR_PRODUCTOS.sql; foto posterior y comparacion: solo pueden cambiar las lineas COLUMNA| y PRIVILEGIO|*_oculto;
              datos, ACL, politicas y disparadores iguales; y los permisos de anon sobre la columna deben ser exactamente los que ya tiene sobre la tabla
              (la columna los hereda: no se concede nada).
  Evidencia: carpeta NUEVA %USERPROFILE%\LaCava-evidencia-local\inventario-ocultar-produccion-<huella>\ (nunca se sobrescribe), sin contrasena, host ni usuario.
  Uso:  powershell -ExecutionPolicy Bypass -File .\INSTALAR-OCULTAR-INVENTARIO-EN-PRODUCCION.ps1 -Accion Verificar|Instalar
  Codigos de salida: 0 correcto - 1 Docker - 2 datos, archivos o estado previo no validos (no escribio) - 3 la escritura FALLO - 4 sin confirmacion o proyecto
    distinto - 5 la comprobacion posterior NO es correcta
#>
param(
  [ValidateSet('Verificar', 'Instalar')][string]$Accion = 'Verificar',
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

$HuellaProduccion = 'cea2aa59bdf95443fef9d9a4b42bab3fd5a77bbb1131ac24b7ddc790eface400'
$PrefijoStaging = 'ca10112ba2'
$Frases = @{ Verificar = 'VERIFICAR OCULTAR EN PRODUCCION'; Instalar = 'INSTALAR OCULTAR EN PRODUCCION' }
$Archivos = [ordered]@{
  'INVENTARIO_OCULTAR_PRODUCTOS.sql'                    = '6f6408ab7b39a71b73cebb5f245a10d46ea9bc3cb30cbd18dae5a1d20bd9bacc'
  'INVENTARIO_OCULTAR_PRODUCTOS_VERIFICAR.sql'          = '60eb028004baed29c91f68482931669ed4825bdcc7f2ae3fbc435126e8070847'
  'INVENTARIO_OCULTAR_PRODUCTOS_PRECHEQUEO_STAGING.sql' = '9d2e0c69544b27d0f6d14b76abce8ddb4f99913ab07a160140418ab632a892e5'
}
$EncabezadoSql = "\set ON_ERROR_STOP on`n"
# Guarda en la propia base: se niega si el proyecto esta marcado como STAGING
$SqlNoEsStaging = @'
DO $$ BEGIN
  IF to_regnamespace('staging_marca') IS NOT NULL THEN
    RAISE EXCEPTION 'FALLO: este proyecto esta marcado como STAGING (existe staging_marca). No se hizo nada.';
  END IF;
END $$;
'@

Escribir-Titulo ('OCULTAR PRODUCTOS EN INVENTARIO en PRODUCCION - accion: ' + $Accion + $(if ($Accion -eq 'Verificar') { ' (solo lectura)' } else { ' (ESCRIBE en produccion)' }))
$problema = Probar-Docker $DockerExe
if ($problema) { Fallar 1 $problema }
$textos = @{}
foreach ($nombre in $Archivos.Keys) {
  $ruta = Join-Path $PSScriptRoot $nombre
  if (-not (Test-Path -LiteralPath $ruta -PathType Leaf)) { Fallar 2 ('Falta ' + $nombre + ' junto al lanzador. No se ejecuto nada.') }
  $textoArchivo = ([IO.File]::ReadAllText($ruta, [Text.Encoding]::UTF8)) -replace "`r`n", "`n"
  $hashArchivo = Hash-Texto $textoArchivo
  Write-Host ('SHA-256 (LF) de ' + $nombre + ': ' + $hashArchivo)
  if ($hashArchivo -ne $Archivos[$nombre]) { Fallar 2 ('El archivo ' + $nombre + ' NO es el aprobado (su SHA-256 cambio). No se ejecuto nada.') }
  $textos[$nombre] = $textoArchivo
}
$hashPropio = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLower()
Write-Host ('SHA-256 de este lanzador: ' + $hashPropio)
$sinCom = (($textos['INVENTARIO_OCULTAR_PRODUCTOS.sql'] -split "`n") | Where-Object { $_ -notmatch '^\s*--' }) -join "`n"
if ($sinCom -match '(?im)\b(CREATE\s+(OR\s+REPLACE\s+)?(FUNCTION|TRIGGER|POLICY|TABLE|ROLE)|GRANT|REVOKE|DELETE|UPDATE|INSERT|TRUNCATE|DROP\s+(TABLE|FUNCTION|TRIGGER|POLICY|ROLE))\b') { Fallar 2 'INVENTARIO_OCULTAR_PRODUCTOS.sql contiene algo distinto de la unica columna prevista. No se ejecuto nada.' }
if ($textos['INVENTARIO_OCULTAR_PRODUCTOS_PRECHEQUEO_STAGING.sql'] -notmatch '(?m)^BEGIN TRANSACTION READ ONLY;') { Fallar 2 'La foto previa no es de solo lectura. No se ejecuto nada.' }

Write-Host ''
Write-Host 'Son los datos del proyecto de PRODUCCION (Supabase > Connect > Session pooler). La contrasena la pedira PostgreSQL (no se ve al escribirla).'
$h = Pedir-Dato $Servidor 'Servidor (host) del Session pooler de PRODUCCION' '^[A-Za-z0-9.-]{3,255}$' 'aws-0-REGION.pooler.supabase.com'
$u = Pedir-Dato $Usuario 'Usuario del pooler de PRODUCCION' '^[A-Za-z0-9._-]{1,128}$' 'postgres.xxxxxxxxxxxxxxxxxxxx'
$b = Pedir-Dato $Base 'Base de datos' '^[A-Za-z0-9_-]{1,63}$' 'postgres'
if ($u -notmatch '^postgres\.([a-z0-9]{20})$') { Fallar 2 'El usuario debe ser el del Session pooler: postgres.XXXXXXXXXXXXXXXXXXXX. No se conecto.' }
$referencia = $Matches[1]
if ($b -notmatch '^[A-Za-z0-9_-]{1,63}$') { Fallar 2 'La base de datos no tiene el formato esperado. No se conecto.' }
if (-not $h.ToLower().EndsWith($SufijoHost.ToLower())) { Fallar 2 ('El servidor debe ser el del Session pooler (termina en ' + $SufijoHost + '). No se conecto.') }
$huellaCompleta = Hash-Texto $referencia
$huellaProyecto = $huellaCompleta.Substring(0, 10)
Write-Host ('Huella del proyecto: ' + $huellaProyecto + '...')
if ($huellaProyecto -eq $PrefijoStaging) { Fallar 4 'RECHAZADO: es el proyecto de STAGING (ca10112ba2). Este lanzador es solo de produccion. No se conecto.' }
if ($huellaCompleta -ne $HuellaProduccion) { Fallar 4 'RECHAZADO: la huella no es la de PRODUCCION (cea2aa59...). No se conecto.' }
Write-Host 'OK: la huella corresponde a PRODUCCION (cea2aa59...).' -ForegroundColor Green
$conexion = 'host=' + $h + ' port=' + $script:PuertoSessionPooler + ' dbname=' + $b + ' user=' + $u + ' sslmode=require'
Write-Host ''
if ($Accion -eq 'Verificar') { Write-Host 'SOLO LECTURA sobre PRODUCCION.' -ForegroundColor Yellow }
else { Write-Host 'ESCRIBE en PRODUCCION: agrega la columna public.inventario.oculto (boolean NOT NULL DEFAULT false), en UNA transaccion. Sin triggers, funciones, politicas ni permisos nuevos. No toca ningun producto.' -ForegroundColor Yellow }
if (-not (Pedir-Confirmacion $Frases[$Accion] $Confirmacion)) { Fallar 4 'DETENIDO: la confirmacion no coincide. No se conecto.' }

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
function Leer-Estado([string]$nombre, [string]$trabajo) {
  $sql = $EncabezadoSql + $SqlNoEsStaging + "`nSELECT 'SECCION|foto';`n" + $textos['INVENTARIO_OCULTAR_PRODUCTOS_PRECHEQUEO_STAGING.sql'] + "`nSELECT 'SECCION|verificador';`n" + $textos['INVENTARIO_OCULTAR_PRODUCTOS_VERIFICAR.sql'] + "`nSELECT 'SECCION|fin';`n"
  $r = Ejecutar-Psql $nombre $sql $trabajo $true
  $sec = @{ foto = @(); verificador = @() }; $actual = $null; $fin = $false
  foreach ($x in $r.lineas) {
    if ($x -like 'SECCION|*') { $actual = $x.Substring(8); if ($actual -eq 'fin') { $fin = $true }; continue }
    if ($actual -and $sec.ContainsKey($actual)) { $sec[$actual] += $x }
  }
  return @{ codigo = $r.codigo; err = $r.err; fin = $fin; foto = $sec.foto; verificador = $sec.verificador }
}
function Es-Variable([string]$l) { return ($l.StartsWith('COLUMNA|') -or ($l -like 'PRIVILEGIO|*_oculto|*')) }

$trabajo = Join-Path ([IO.Path]::GetTempPath()) ('lacava-ocultar-prod-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $trabajo | Out-Null
try {
  Escribir-Titulo 'Sesion 1: foto previa de PRODUCCION (solo lectura)...'
  $antes = Leer-Estado 'antes' $trabajo
  if ($antes.codigo -ne 0 -or -not $antes.fin -or -not ($antes.foto -contains 'RESULTADO|OK')) { Fallar 2 ('La foto previa no termino (codigo ' + $antes.codigo + '). No se escribio nada. ' + $antes.err) }
  $existeTxt = ($antes.foto | Where-Object { $_ -like 'COLUMNA|oculto_existe|*' }) -replace '^COLUMNA\|oculto_existe\|', ''
  $existe = ($existeTxt -eq 'true')
  Write-Host ('Columna oculto existe antes: ' + $existe)
  if ((Valor-Linea $antes.foto 'ESTADO|staging_marca') -ne 'false') { Fallar 2 'El proyecto tiene el esquema staging_marca: NO es produccion. No se escribio nada.' }
  if ((Valor-Linea $antes.foto 'TABLA|inventario_existe') -ne 'true') { Fallar 2 'No existe public.inventario. No se escribio nada.' }
  $dueno = Valor-Linea $antes.foto 'TABLA|inventario_dueno'
  if ($Accion -eq 'Instalar') {
    if ($dueno -notlike '*usuario_es_dueno_o_miembro=true') { Fallar 2 ('El usuario no es dueno de public.inventario (' + $dueno + '): no podria alterar la tabla. No se cambio el dueno ni se amplio ningun privilegio. No se escribio nada.') }
    if ($existe) { Fallar 2 'La columna oculto YA existe: no hay nada que instalar. No se escribio nada.' }
  }

  $escrituraOk = $true; $escrituraErr = ''; $escrituraCodigo = 0
  if ($Accion -eq 'Instalar') {
    Escribir-Titulo 'Sesion 2: INSTALAR en PRODUCCION (una transaccion, lock_timeout 5 s; se detiene ante el primer error)...'
    $sqlEscribir = $EncabezadoSql + $SqlNoEsStaging + "`nBEGIN;`nSET LOCAL lock_timeout = '5s';`n" + $textos['INVENTARIO_OCULTAR_PRODUCTOS.sql'] + "`nCOMMIT;`n"
    $e = Ejecutar-Psql 'escribir' $sqlEscribir $trabajo $false
    $escrituraCodigo = $e.codigo; $escrituraOk = ($e.codigo -eq 0); $escrituraErr = $e.err
    if ($escrituraOk) { Write-Host 'La escritura termino sin errores (COMMIT).' -ForegroundColor Green }
    else { Write-Host ('LA ESCRITURA FALLO (codigo ' + $e.codigo + '). Se deshizo todo. Error:') -ForegroundColor Red; Write-Host $e.err }
  }

  Escribir-Titulo ('Sesion ' + $(if ($Accion -eq 'Verificar') { '2' } else { '3' }) + ': estado REAL (solo lectura)...')
  $despues = Leer-Estado 'despues' $trabajo
  $fallos = @()
  if ($despues.codigo -ne 0 -or -not $despues.fin) { $fallos += ('la lectura posterior no termino (codigo ' + $despues.codigo + ')') }
  $fijasAntes = @($antes.foto | Where-Object { -not (Es-Variable $_) }); $fijasDespues = @($despues.foto | Where-Object { -not (Es-Variable $_) })
  $dif = @(Compare-Object $fijasAntes $fijasDespues)
  if ($dif.Count -gt 0) { $fallos += ('hay diferencias distintas de la columna oculto: ' + $dif.Count) }
  $existeDespues = (($despues.foto | Where-Object { $_ -like 'COLUMNA|oculto_existe|*' }) -replace '^COLUMNA\|oculto_existe\|', '') -eq 'true'
  $verTexto = ($despues.verificador -join ' / ')
  # permisos: la columna hereda los de la tabla; anon no gana nada
  $tablaAnon = Valor-Linea $despues.foto 'PRIVILEGIO|anon_tabla'; $tablaAuth = Valor-Linea $despues.foto 'PRIVILEGIO|authenticated_tabla'
  $esperadoAnon = 'SELECT=' + ($tablaAnon -match 'SELECT').ToString().ToLower() + ',UPDATE=' + ($tablaAnon -match 'UPDATE').ToString().ToLower()
  $esperadoAuth = 'SELECT=' + ($tablaAuth -match 'SELECT').ToString().ToLower() + ',UPDATE=' + ($tablaAuth -match 'UPDATE').ToString().ToLower()
  if ($Accion -eq 'Instalar' -and $escrituraOk) {
    if (-not $existeDespues) { $fallos += 'la columna no existe tras instalar' }
    if (-not ($despues.foto -contains 'COLUMNA|oculto_definicion|boolean|nullable=NO|default=false')) { $fallos += 'la definicion de la columna no es boolean NOT NULL DEFAULT false' }
    if (-not ($despues.verificador | Where-Object { $_ -like 'INSTALADO|*|0' })) { $fallos += 'el verificador no reporta INSTALADO con 0 productos ocultos' }
    if ((Valor-Linea $despues.foto 'PRIVILEGIO|anon_oculto') -ne $esperadoAnon) { $fallos += ('anon sobre la columna (' + (Valor-Linea $despues.foto 'PRIVILEGIO|anon_oculto') + ') no coincide con lo que ya tenia sobre la tabla (' + $esperadoAnon + ')') }
    if ((Valor-Linea $despues.foto 'PRIVILEGIO|authenticated_oculto') -ne $esperadoAuth) { $fallos += ('authenticated sobre la columna (' + (Valor-Linea $despues.foto 'PRIVILEGIO|authenticated_oculto') + ') no coincide con la tabla (' + $esperadoAuth + ')') }
  }
  $dictamen = if (-not $escrituraOk) { 'ESCRITURA FALLIDA (se deshizo todo): el estado real esta arriba' }
              elseif ($fallos.Count -eq 0) { if ($Accion -eq 'Verificar') { 'ESTADO LEIDO: ' + $verTexto } else { 'INSTALADO Y VERIFICADO: solo cambio la columna oculto; permisos de anon iguales a los de la tabla' } }
              else { 'CON PROBLEMAS: ' + ($fallos -join '; ') }

  $dirNuevo = Join-Path $Evidencia ('inventario-ocultar-produccion-' + $huellaProyecto)
  New-Item -ItemType Directory -Path $dirNuevo -Force | Out-Null
  $ruta = Join-Path $dirNuevo ($Accion.ToUpper() + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt')
  $texto = (@('EVIDENCIA OCULTAR PRODUCTOS EN INVENTARIO - PRODUCCION (sin contrasenas, host, usuario, URLs ni datos de clientes)',
      ('accion: ' + $Accion), ('fecha_local: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')), ('huella_proyecto: ' + $huellaProyecto), ('lanzador_sha256: ' + $hashPropio)) +
    @($Archivos.Keys | ForEach-Object { 'sha256 ' + $_ + ': ' + $Archivos[$_] }) +
    @(('escritura_codigo_de_salida: ' + $escrituraCodigo), 'escritura_mensajes_y_errores:') + @(($escrituraErr -split "`n") | ForEach-Object { '  ' + $_.TrimEnd() } | Where-Object { $_.Trim() }) +
    @('foto_antes:') + @($antes.foto | ForEach-Object { '  ' + $_ }) + @('foto_despues:') + @($despues.foto | ForEach-Object { '  ' + $_ }) +
    @('verificador_despues:') + @($despues.verificador | ForEach-Object { '  ' + $_ }) +
    @(('diferencias_distintas_de_la_columna (debe ser ninguna): ' + $(if ($dif.Count) { '' } else { 'ninguna' }))) + @($dif | ForEach-Object { '  ' + $_.InputObject + '  ' + $_.SideIndicator }) +
    @(('dictamen: ' + $dictamen), 'cambios_en_produccion: ' + $(if ($Accion -eq 'Verificar') { 'ninguno (solo lectura)' } else { 'solo la columna public.inventario.oculto' }), 'contrasena: no registrada (la pidio PostgreSQL)', '')) -join "`n"
  $fs = [IO.File]::Open($ruta, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
  try { $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($texto); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
  Write-Host ''; Write-Host $texto; Write-Host ''; Write-Host ('Evidencia: ' + $ruta)
  if (-not $escrituraOk) { Escribir-Titulo 'LA ESCRITURA FALLO. Estado real arriba. No se cambio el dueno ni se amplio ningun privilegio.'; exit 3 }
  if ($fallos.Count -gt 0) { Escribir-Titulo 'LA COMPROBACION POSTERIOR NO ES CORRECTA. Revisa la evidencia.'; exit 5 }
  Escribir-Titulo ('CORRECTO: ' + $dictamen)
  exit 0
}
finally { if (Test-Path -LiteralPath $trabajo) { Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue } }
