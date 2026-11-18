<#
  LECTURA (SOLO LECTURA) DEL UUID EXACTO DEL USUARIO CON PERFIL ACTIVO EN STAGING (ca10112ba2).
  No cambia nada: sesion con default_transaction_read_only=on y BEGIN READ ONLY ... ROLLBACK. No lee contrasenas ni hashes.
  Mismas defensas de los lanzadores de staging (STAGING-COMUN.ps1, que solo se LEE): rechaza produccion, exige el Session
  pooler, la huella ca10112ba2 y el esquema staging_marca, fija el SHA-256 de la consulta y pide la frase LEER PERFIL EN STAGING.
  Condicion para dar un UUID: EXACTAMENTE 1 perfil activo, y su usuario de Auth existe y tiene correo .invalid (ficticio).
  Uso:  powershell -ExecutionPolicy Bypass -File .\LEER-PERFIL-ENSAYO-STAGING.ps1
  Codigos de salida: 0 UUID confirmado - 1 Docker - 2 datos o archivos no validos - 3 fallo de la sesion - 4 sin confirmacion o
  proyecto distinto - 5 NO se puede confirmar un unico usuario ficticio con perfil activo
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

$Frase = 'LEER PERFIL EN STAGING'
$ArchivoSql = 'PERFIL_ENSAYO_STAGING.sql'
$HashSql = '7f7fe5043eabd5fe450fe06d88f43a129e18e6b0887b6e43f7cea5e764c96f29'
Escribir-Titulo 'Lectura (solo lectura) del usuario con perfil activo en STAGING - La Cava'
$problema = Probar-Docker $DockerExe
if ($problema) { Fallar 1 $problema }
$rutaSql = Join-Path $PSScriptRoot $ArchivoSql
if (-not (Test-Path -LiteralPath $rutaSql -PathType Leaf)) { Fallar 2 ('Falta ' + $ArchivoSql + '. No se ejecuto nada.') }
$hashSql = (Get-FileHash -LiteralPath $rutaSql -Algorithm SHA256).Hash.ToLower()
Write-Host ('SHA-256 de ' + $ArchivoSql + ': ' + $hashSql)
if ($hashSql -ne $HashSql) { Fallar 2 'La consulta NO es la aprobada (su SHA-256 cambio). No se ejecuto nada.' }
$sqlTexto = [IO.File]::ReadAllText($rutaSql, [Text.Encoding]::UTF8)
$sinComentarios = (($sqlTexto -split "`n") | Where-Object { $_ -notmatch '^\s*--' }) -join "`n"
if ($sinComentarios -match '(?im)^\s*(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|GRANT|REVOKE|TRUNCATE|NOTIFY|COPY|CALL|DO)\b') { Fallar 2 'La consulta contiene una sentencia que escribe. No se ejecuto nada.' }
$hashPropio = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLower()

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
Write-Host ''
Write-Host ('Lectura de SOLO LECTURA sobre el proyecto de STAGING con huella ' + $huellaProyecto + '.') -ForegroundColor Yellow
if (-not (Pedir-Confirmacion $Frase $Confirmacion)) { Fallar 4 'DETENIDO: la confirmacion no coincide. No se conecto.' }

$trabajo = Join-Path ([IO.Path]::GetTempPath()) ('lacava-perfil-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $trabajo | Out-Null
try {
  $sql = "\set ON_ERROR_STOP on`n" + $script:SqlMarcaStaging + "`n" + $sqlTexto
  Escribir-Titulo 'Leyendo staging (sesion de solo lectura)...'
  Ejecutar-Sesion 'perfil' $sql $conexion $trabajo $true
  $s = $script:Sesion
  if ($s.codigo -ne 0 -or (Valor-Linea $s.lineas 'RESULTADO') -ne 'OK') { Fallar 3 'FALLO: la lectura no termino (ver el mensaje de arriba). No se cambio nada.' }
  $lineas = @($s.lineas | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
  $activos = Valor-Linea $lineas 'PERFIL|activos'
  $filas = @($lineas | Where-Object { $_ -like 'AUTH|usuario_del_perfil|*' })
  $uuid = $null; $motivos = @()
  if ((Valor-Linea $lineas 'ESTADO|staging_marca') -ne 'true') { $motivos += 'el proyecto no esta marcado como staging' }
  if ($activos -ne '1') { $motivos += ('se esperaba exactamente 1 perfil activo y hay ' + $activos) }
  if ($filas.Count -ne 1) { $motivos += ('se esperaba exactamente 1 usuario de Auth con perfil activo y hay ' + $filas.Count) }
  else {
    $p = $filas[0] -split '\|'
    if ($p[2] -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { $motivos += 'el identificador no tiene formato UUID' } else { $uuid = $p[2].ToLower() }
    if ($filas[0] -notlike '*correo_termina_en_invalid=true') { $motivos += 'el correo del usuario NO termina en .invalid: no es el usuario ficticio' }
    $perfil = @($lineas | Where-Object { $_ -like 'PERFIL|user_id|*' })
    if ($perfil.Count -ne 1 -or ($perfil[0] -split '\|')[2].ToLower() -ne $uuid) { $motivos += 'el usuario de Auth no coincide con el del perfil' }
  }
  $dir = Join-Path $Evidencia ('hotfix-staging-' + $huellaProyecto); New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $ruta = Join-Path $dir ('PERFIL-ENSAYO-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt')
  $texto = (@('EVIDENCIA: USUARIO FICTICIO CON PERFIL ACTIVO EN STAGING (solo lectura; sin contrasenas, hashes, host, usuario ni URLs)', ('fecha_local: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')),
      ('huella_proyecto_staging: ' + $huellaProyecto), ('lanzador_sha256: ' + $hashPropio), ('consulta_sha256: ' + $hashSql), 'salida:') + @($lineas | ForEach-Object { '  ' + $_ }) +
    @(('uuid_del_perfil_activo: ' + $(if ($uuid -and $motivos.Count -eq 0) { $uuid } else { '(no confirmado)' })), ('motivos: ' + $(if ($motivos.Count) { $motivos -join '; ' } else { 'ninguno' })), 'cambios_en_staging: ninguno (solo lectura)', '')) -join "`n"
  $fs = [IO.File]::Open($ruta, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
  try { $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($texto); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
  Write-Host ''; Write-Host $texto; Write-Host ('Evidencia: ' + $ruta)
  if ($motivos.Count -gt 0) { Escribir-Titulo 'NO se puede confirmar un unico usuario ficticio con perfil activo.'; exit 5 }
  Escribir-Titulo ('UUID CONFIRMADO del usuario con perfil activo: ' + $uuid)
  exit 0
}
finally { if (Test-Path -LiteralPath $trabajo) { Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue } }
