<#
  FASE ANON TEMPORAL DEL ENSAYO DEL HOTFIX EN STAGING (ca10112ba2). ESCRIBE (permisos) en STAGING; jamas contra produccion.
  Autorizada por Michel para cerrar las comprobaciones previas al deploy. Ver PLAN_ENSAYO_HOTFIX_EN_STAGING.md (fase 2).
  Defensas (las de los demas lanzadores de staging, de STAGING-COMUN.ps1, que solo se LEE): rechaza produccion por su huella,
  exige el Session pooler, la huella ca10112ba2, el esquema staging_marca, fija el SHA-256 de los 3 SQL y pide una frase.
  Que hace:
    SESION 1 (escritura, una sola conexion): CAPTURA las ACL y politicas -> APERTURA minima (una transaccion) -> CAPTURA de nuevo.
    ESPERA mientras Claude prueba (Enter para terminar; restauracion AUTOMATICA al llegar al limite de minutos o si cierras/interrumpes).
    SESION 2: RESTAURACION (una transaccion) -> CAPTURA. Compara la captura final con la de ANTES: deben ser IDENTICAS.
    La restauracion se ejecuta SIEMPRE (tambien si la apertura o una prueba fallo). Si no se puede restaurar o hay diferencias, lo
    dice en rojo, con el codigo 6, y se detiene todo.
  Evidencia: %USERPROFILE%\LaCava-evidencia-local\hotfix-staging-ca10112ba2\ (nunca se sobrescribe; sin contrasena, host, usuario ni URLs).
  Uso:  powershell -ExecutionPolicy Bypass -File .\FASE-ANON-ENSAYO-STAGING.ps1
  Codigos de salida: 0 restaurado e identico - 1 Docker - 2 datos o archivos no validos - 3 la apertura fallo (restaurado) -
    4 sin confirmacion o proyecto distinto - 6 RESTAURACION FALLIDA O CON DIFERENCIAS (avisar de inmediato)
#>
param(
  [string]$ProyectoEsperado = 'ca10112ba2',
  [string]$Servidor, [string]$Usuario, [string]$Base, [string]$Confirmacion,
  [int]$MinutosMaximo = 45,
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

$Frase = 'ABRIR ACCESO ANON TEMPORAL EN STAGING'
$Archivos = [ordered]@{
  'ANON_ENSAYO_STAGING_CAPTURA.sql'   = 'a3ffc3073d25af970cde5b0f40126803684fe86e30f57a16777d292cd5dc48ca'
  'ANON_ENSAYO_STAGING_ABRIR.sql'     = 'ba06fc120c0bcd8b2495afa3628cf85692a82b61938b4edadb6b69ea536909f1'
  'ANON_ENSAYO_STAGING_RESTAURAR.sql' = '4855dc90f94feb70ede5049e93caa6f7b38be0cece569e775e639b8ae0aff1b3'
}
$EncabezadoSql = "\set ON_ERROR_STOP on`n"
Escribir-Titulo 'FASE ANON TEMPORAL en STAGING (abre permisos minimos y los restaura) - La Cava'
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
$sqlAbrir = $textos['ANON_ENSAYO_STAGING_ABRIR.sql']; $sqlRest = $textos['ANON_ENSAYO_STAGING_RESTAURAR.sql']; $sqlCapt = $textos['ANON_ENSAYO_STAGING_CAPTURA.sql']
foreach ($par in @(@('ABRIR', $sqlAbrir), @('RESTAURAR', $sqlRest))) {
  if ((([regex]::Matches($par[1], '(?m)^BEGIN;\s*$')).Count -ne 1) -or (([regex]::Matches($par[1], '(?m)^COMMIT;\s*$')).Count -ne 1)) { Fallar 2 ('El SQL ' + $par[0] + ' no es UNA sola transaccion. No se ejecuto nada.') }
}
$sinCom = (($sqlAbrir -split "`n") | Where-Object { $_ -notmatch '^\s*--' }) -join "`n"
if ($sinCom -match '(?im)^\s*GRANT\s+[^;]*\bDELETE\b|^\s*GRANT\s+ALL\b|\bTO\s+(public|authenticated|service_role)\b') { Fallar 2 'La apertura concede DELETE, ALL o permisos a otro rol. No se ejecuto nada.' }

Write-Host ''
Write-Host 'Son los datos del proyecto de STAGING (Supabase > Connect > Session pooler). La contrasena la pedira PostgreSQL DOS VECES (apertura y restauracion). No se ve nada al escribirla: escribela y pulsa Enter.'
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
Write-Host ('APERTURA TEMPORAL en el proyecto de STAGING con huella ' + $huellaProyecto + ': anon podra leer 8 tablas, crear clientes y cotizaciones, modificar cotizaciones y ejecutar las 2 funciones del hotfix. Se restaura al terminar (maximo ' + $MinutosMaximo + ' minutos).') -ForegroundColor Yellow
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
function Separar-Etapas([string[]]$lineas) {
  $e = @{}; $actual = $null
  foreach ($x in $lineas) {
    if ($x -like 'ETAPA|*') { $actual = $x.Substring(6); $e[$actual] = @(); continue }
    if ($actual -and $x -like 'CAPT|*') { $e[$actual] += $x }
  }
  return $e
}
function Escribir-Evidencia([string]$nombre, [string]$texto) {
  $dir = Join-Path $Evidencia ('hotfix-staging-' + $huellaProyecto); New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $ruta = Join-Path $dir ($nombre + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt')
  $fs = [IO.File]::Open($ruta, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
  try { $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($texto); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
  return $ruta
}
$cabecera = @('(sin contrasenas, host, usuario, URLs ni llaves)', ('fecha_local: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')), ('huella_proyecto_staging: ' + $huellaProyecto), ('lanzador_sha256: ' + $hashPropio)) + @($Archivos.Keys | ForEach-Object { 'sha256 ' + $_ + ': ' + $Archivos[$_] })

$trabajo = Join-Path ([IO.Path]::GetTempPath()) ('lacava-anon-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $trabajo | Out-Null
$abiertoIntentado = $false; $restaurado = $false; $codigoSalida = 0; $antes = @(); $abierto = @(); $despues = @(); $aperturaOk = $false; $errApertura = ''; $diferencias = @(); $errRest = ''
try {
  # ---- SESION 1: captura -> apertura -> captura
  Escribir-Titulo 'Sesion 1: CAPTURA de ACL y politicas, APERTURA minima (una transaccion) y nueva captura...'
  $sql1 = $EncabezadoSql + $script:SqlMarcaStaging + "`nSELECT 'ETAPA|antes';`n" + $sqlCapt + "`nSELECT 'ETAPA|aplicando';`n"
  $abiertoIntentado = $true
  $sql1 += $sqlAbrir + "`nSELECT 'ETAPA|abierto';`n" + $sqlCapt + "`nSELECT 'ETAPA|fin1';`n"
  $s1 = Ejecutar-Psql 'sesion1' $sql1 $trabajo
  $et1 = Separar-Etapas $s1.lineas
  if ($et1.ContainsKey('antes')) { $antes = $et1['antes'] }
  if ($et1.ContainsKey('abierto')) { $abierto = $et1['abierto'] }
  $aperturaOk = ($s1.codigo -eq 0 -and $s1.lineas -contains 'ETAPA|fin1')
  if ($antes.Count -gt 0) { $rutaAntes = Escribir-Evidencia 'ANON-ANTES' ((@('EVIDENCIA: ACL Y POLITICAS INMEDIATAMENTE ANTES DE LA APERTURA ANON') + $cabecera + @('lineas: ' + $antes.Count, 'captura:') + @($antes | ForEach-Object { '  ' + $_ }) + @('')) -join "`n"); Write-Host ('Captura previa guardada: ' + $rutaAntes) }
  else { Write-Host 'AVISO: no se obtuvo la captura previa (la sesion no llego a leer).' -ForegroundColor Red }
  if ($aperturaOk) {
    Write-Host ''; Write-Host 'ACCESO ANON TEMPORAL ABIERTO.' -ForegroundColor Green
    Write-Host 'AHORA: avisa a Claude. Claude hara las pruebas por el servidor local en modo solo anon (otra pestana).'
    Write-Host ('Cuando Claude diga "terminado", vuelve aqui y pulsa ENTER para RESTAURAR. Si no pulsas nada, se restaura sola en ' + $MinutosMaximo + ' minutos (a las ' + (Get-Date).AddMinutes($MinutosMaximo).ToString('HH:mm') + ').') -ForegroundColor Yellow
    $limite = (Get-Date).AddMinutes($MinutosMaximo)
    try {
      while ((Get-Date) -lt $limite) {
        if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq 'Enter') { break } }
        Start-Sleep -Milliseconds 400
      }
    } catch { $null = Read-Host 'Pulsa ENTER para restaurar' }
    Write-Host 'Restaurando...' -ForegroundColor Cyan
  } else {
    $errApertura = $s1.err
    Write-Host ('LA APERTURA FALLO (codigo ' + $s1.codigo + '). Error de Supabase/PostgreSQL:') -ForegroundColor Red; Write-Host $errApertura
    Write-Host 'Se restaura de todos modos (idempotente) y se compara con la captura previa.' -ForegroundColor Yellow
  }
}
finally {
  # ---- SESION 2: RESTAURACION (siempre que se intento abrir), con hasta 3 intentos
  if ($abiertoIntentado -and -not $restaurado) {
    Escribir-Titulo 'Sesion 2: RESTAURACION exacta (una transaccion) y captura final...'
    $sql2 = $EncabezadoSql + $script:SqlMarcaStaging + "`n" + $sqlRest + "`nSELECT 'ETAPA|restaurado';`n" + $sqlCapt + "`nSELECT 'ETAPA|fin2';`n"
    for ($intento = 1; $intento -le 3 -and -not $restaurado; $intento++) {
      $s2 = Ejecutar-Psql 'sesion2' $sql2 $trabajo
      if ($s2.codigo -eq 0 -and $s2.lineas -contains 'ETAPA|fin2') { $restaurado = $true; $despues = (Separar-Etapas $s2.lineas)['restaurado'] }
      else { $errRest = $s2.err; Write-Host ('Intento ' + $intento + ' de restauracion NO termino (codigo ' + $s2.codigo + '). ' + $s2.err) -ForegroundColor Red }
    }
    $diferencias = @()
    if ($restaurado -and $antes.Count -gt 0) {
      $d = Compare-Object -ReferenceObject $antes -DifferenceObject $despues
      $diferencias = @($d | ForEach-Object { ($(if ($_.SideIndicator -eq '<=') { 'ANTES (ya no esta): ' } else { 'DESPUES (nuevo): ' })) + $_.InputObject })
    }
    $estado = if (-not $restaurado) { 'RESTAURACION FALLIDA: la apertura puede seguir activa' } elseif ($antes.Count -eq 0) { 'RESTAURADO pero SIN captura previa: no se puede comparar' } elseif ($diferencias.Count -gt 0) { 'RESTAURADO CON DIFERENCIAS respecto de la captura previa' } else { 'RESTAURADO: la captura final es IDENTICA a la previa (' + $antes.Count + ' lineas)' }
    $texto = (@('EVIDENCIA DE LA FASE ANON TEMPORAL (apertura, restauracion y comparacion)') + $cabecera +
      @(('apertura_ok: ' + $aperturaOk), ('apertura_error: ' + $(if ($errApertura) { $errApertura.Trim() } else { 'ninguno' })), ('restauracion_ok: ' + $restaurado), ('restauracion_error: ' + $(if ($errRest) { $errRest.Trim() } else { 'ninguno' })),
        ('lineas_antes: ' + $antes.Count), ('lineas_abierto: ' + $abierto.Count), ('lineas_despues: ' + $despues.Count), ('diferencias_antes_vs_despues: ' + $(if ($diferencias.Count) { $diferencias.Count } else { 'ninguna' }))) +
      @($diferencias | ForEach-Object { '  ' + $_ }) + @('cambios_durante_la_apertura (abierto vs antes):') +
      @(if ($abierto.Count) { (Compare-Object -ReferenceObject $antes -DifferenceObject $abierto | ForEach-Object { '  ' + $(if ($_.SideIndicator -eq '<=') { '- ' } else { '+ ' }) + $_.InputObject }) }) +
      @(('dictamen: ' + $estado), '')) -join "`n"
    $rutaFin = Escribir-Evidencia 'ANON-RESTAURACION' $texto
    Write-Host ''; Write-Host $texto; Write-Host ('Evidencia: ' + $rutaFin)
    if (-not $restaurado -or $diferencias.Count -gt 0 -or $antes.Count -eq 0) {
      Write-Host ''; Write-Host 'RESTAURACION FALLIDA O CON DIFERENCIAS. AVISA A CLAUDE DE INMEDIATO Y NO HAGAS NADA MAS.' -ForegroundColor Red
      $codigoSalida = 6
    } elseif (-not $aperturaOk) { $codigoSalida = 3 } else { Escribir-Titulo 'RESTAURADO Y COMPARADO: sin diferencias.'; $codigoSalida = 0 }
  }
  if (Test-Path -LiteralPath $trabajo) { Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $codigoSalida
