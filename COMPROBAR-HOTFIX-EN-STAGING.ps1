<#
  PRIMER PASO DEL ENSAYO DEL HOTFIX DE COTIZACIONES EN STAGING (SOLO LECTURA). Ver PLAN_ENSAYO_HOTFIX_EN_STAGING.md.
  No cambia nada en staging: la sesion corre con default_transaction_read_only=on y dentro de BEGIN READ ONLY ... ROLLBACK.
  Usa las MISMAS defensas de los lanzadores de staging existentes (STAGING-COMUN.ps1, de la copia de integracion, que
  solo se LEE): rechaza produccion por su huella SHA-256, exige el Session pooler, exige la huella del proyecto de
  staging esperado (ca10112ba2), exige el esquema staging_marca y pide la frase COMPROBAR EN STAGING.
  Que responde (PRECHEQUEO_HOTFIX_EN_STAGING.sql):
    - si HOTFIX_COT_CONVERSION_ATOMICA.sql se puede instalar tal cual (requisitos y colisiones);
    - quien instalaria (rol, CREATEROLE, membresias) y el dueno de las tablas;
    - ACL exacta, politicas, disparadores y RLS de las tablas que toca (para poder restaurar un ensayo con permisos temporales);
    - conteos de datos, secuencias y perfiles de H1 (sin contenido de clientes).
  Evidencia: una carpeta NUEVA, %USERPROFILE%\LaCava-evidencia-local\hotfix-staging-<huella>\, con archivos que nunca se
  sobrescriben. No toca la evidencia ni los dumps de staging existentes. No guarda contrasena, URL ni llaves.
  Uso:  powershell -ExecutionPolicy Bypass -File .\COMPROBAR-HOTFIX-EN-STAGING.ps1
  Parametros opcionales: -ProyectoEsperado (huella de 10 caracteres; por defecto ca10112ba2), -Servidor, -Usuario, -Base,
    -Confirmacion, -DockerExe, -SufijoHost, -Comun (ruta de STAGING-COMUN.ps1), -Evidencia (carpeta base de la evidencia)
  Codigos de salida: 0 APTO para instalar (nada que impida el ensayo) - 1 Docker no disponible - 2 datos o archivos no validos
    - 3 fallo de la sesion - 4 sin confirmacion o proyecto distinto - 5 NO APTO (ver la evidencia)
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

$Frase = 'COMPROBAR EN STAGING'
$ArchivoSql = 'PRECHEQUEO_HOTFIX_EN_STAGING.sql'
$EncabezadoSql = "\set ON_ERROR_STOP on`n"

Escribir-Titulo 'Comprobacion previa (solo lectura) del hotfix de cotizaciones en STAGING --- La Cava'
$problema = Probar-Docker $DockerExe
if ($problema) { Fallar 1 $problema }
$rutaSql = Join-Path $PSScriptRoot $ArchivoSql
if (-not (Test-Path -LiteralPath $rutaSql -PathType Leaf)) { Fallar 2 ('Falta ' + $ArchivoSql + ' junto al lanzador. No se ejecuto nada.') }
$hashSql = (Get-FileHash -LiteralPath $rutaSql -Algorithm SHA256).Hash.ToLower()
$hashPropio = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLower()
Write-Host ('SHA-256 de este lanzador: ' + $hashPropio)
Write-Host ('SHA-256 de ' + $ArchivoSql + ': ' + $hashSql)
$sqlTexto = [IO.File]::ReadAllText($rutaSql, [Text.Encoding]::UTF8)
$sinComentarios = (($sqlTexto -split "`n") | Where-Object { $_ -notmatch '^s*--' }) -join "`n"
if ($sinComentarios -match '(?im)^s*(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|GRANT|REVOKE|TRUNCATE|NOTIFY|COPY|CALL|DO)') { Fallar 2 'La consulta contiene una sentencia que escribe. No se ejecuto nada.' }
if ($sinComentarios -match '(?i)(nextval|setval|pg_advisory|set_config)') { Fallar 2 'La consulta usa una funcion que podria cambiar estado. No se ejecuto nada.' }

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
Write-Host ('Comprobacion de SOLO LECTURA sobre el proyecto de STAGING con huella ' + $huellaProyecto + '.') -ForegroundColor Yellow
if (-not (Pedir-Confirmacion $Frase $Confirmacion)) { Fallar 4 'DETENIDO: la confirmacion no coincide. No se conecto.' }

$trabajo = Join-Path ([IO.Path]::GetTempPath()) ('lacava-hotfix-precheck-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $trabajo | Out-Null
try {
  $sql = $EncabezadoSql + $script:SqlMarcaStaging + "`n" + $sqlTexto
  Escribir-Titulo 'Leyendo staging (sesion de solo lectura)...'
  Ejecutar-Sesion 'precheck-hotfix' $sql $conexion $trabajo $true
  $s = $script:Sesion
  if ($s.codigo -ne 0 -or (Valor-Linea $s.lineas 'RESULTADO') -ne 'OK') { Fallar 3 'FALLO: la comprobacion no termino (ver el mensaje de arriba). No se cambio nada.' }
  $lineas = @($s.lineas | ForEach-Object { "$_".Trim() } | Where-Object { $_ })

  $v = { param($k) Valor-Linea $lineas $k }
  $motivos = @()
  if ((& $v 'ESTADO|transaccion_solo_lectura') -ne 'on') { $motivos += 'la sesion no era de solo lectura' }
  if ((& $v 'ESTADO|staging_marca') -ne 'true') { $motivos += 'el proyecto no esta marcado como staging' }
  if ((& $v 'ESTADO|hotfix_instalado') -ne 'false') { $motivos += 'el hotfix ya esta (parcialmente) instalado' }
  if ((& $v 'ROL|existe_cotconv_ejecutor') -ne 'false') { $motivos += 'el rol cotconv_ejecutor ya existe' }
  if ((& $v 'REQUISITO|columnas_que_faltan') -ne 'ninguna') { $motivos += ('faltan columnas: ' + (& $v 'REQUISITO|columnas_que_faltan')) }
  foreach ($k in @('REQUISITO|idx_ventas_cotizacion_unica', 'REQUISITO|cartera_venta_id_unique', 'REQUISITO|secuencia_ventas_numero_venta_seq')) { if ((& $v $k) -ne 'true') { $motivos += ('falta ' + $k) } }
  if ((& $v 'REQUISITO|inventario_sin_licencia') -ne '0') { $motivos += 'hay productos sin licencia' }
  foreach ($k in @('COLISION|politicas_cotconv', 'COLISION|funciones_hotfix')) { if ((& $v $k) -ne '0') { $motivos += ('colision: ' + $k) } }
  if ((& $v 'COLISION|tabla_registro') -ne 'false') { $motivos += 'ya existe la tabla cotizacion_conversiones' }
  $rol = @($lineas | Where-Object { $_ -like 'ROL|actual|*' })[0]
  if (-not $rol -or $rol -notmatch 'createrole=true') { $motivos += 'el rol que instalaria no puede crear roles (CREATEROLE)' }
  foreach ($t in @('cotizaciones', 'clientes_frecuentes', 'inventario', 'ventas', 'detalle_ventas', 'cartera', 'cartera_abonos')) {
    $fila = @($lineas | Where-Object { $_ -like ('TABLA|' + $t + '|*') })[0]
    if (-not $fila -or $fila -notlike '*existe=true*') { $motivos += ('falta la tabla ' + $t) }
    elseif ($rol -and $fila -notmatch ('dueno=' + [regex]::Escape(($rol -split '\|')[2]))) { $motivos += ('el rol que instalaria no es el dueno de ' + $t) }
  }
  if ([int](& $v 'DATOS|cotizaciones_convertidas_sin_venta') -ne 0) { $motivos += 'hay cotizaciones convertidas sin venta' }
  $apto = ($motivos.Count -eq 0)

  $dirNuevo = Join-Path $Evidencia ('hotfix-staging-' + $huellaProyecto)
  New-Item -ItemType Directory -Path $dirNuevo -Force | Out-Null
  $ruta = Join-Path $dirNuevo ('PRECHEQUEO-HOTFIX-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt')
  $texto = (@('EVIDENCIA DEL PRECHEQUEO (SOLO LECTURA) DEL HOTFIX DE COTIZACIONES EN STAGING (sin contrasenas, URLs, llaves ni datos de clientes)',
      ('fecha_local: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')), ('huella_proyecto_staging: ' + $huellaProyecto),
      ('lanzador_sha256: ' + $hashPropio), ('consulta_sha256: ' + $hashSql), 'salida_de_la_consulta:') + @($lineas | ForEach-Object { '  ' + $_ }) +
    @(('motivos_que_impiden_instalar: ' + $(if ($apto) { 'ninguno' } else { $motivos -join '; ' })),
      ('dictamen: ' + $(if ($apto) { 'APTO: nada impide instalar HOTFIX_COT_CONVERSION_ATOMICA.sql (la instalacion sigue requiriendo autorizacion)' } else { 'NO APTO: no instalar; decide Michel' })),
      'cambios_en_staging: ninguno (sesion de solo lectura)', 'contrasena: no registrada (la pidio PostgreSQL)', '')) -join "`n"
  $fs = [IO.File]::Open($ruta, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
  try { $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($texto); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }

  Write-Host ''
  Write-Host $texto
  if (-not $apto) { Escribir-Titulo 'NO APTO. Evidencia guardada aparte.'; Write-Host ('Evidencia: ' + $ruta); exit 5 }
  Escribir-Titulo 'APTO. No se cambio nada en staging.'
  Write-Host ('Evidencia: ' + $ruta)
  exit 0
}
finally { if (Test-Path -LiteralPath $trabajo) { Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue } }
