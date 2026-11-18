<#
  VERIFICA UN RESPALDO RESTAURANDOLO EN LOCAL (no solo su hash). No se conecta a Supabase ni a ningun servidor remoto.
  Entrada: un respaldo pg_dump (formato custom) de La Cava -p. ej. el que deja RESPALDAR-PRODUCCION-SOLO-LECTURA.ps1- y su manifiesto.
  Que hace:
    1. Comprueba el SHA-256 del respaldo contra el del manifiesto (y el tamano).
    2. Levanta un PostgreSQL 17 DESECHABLE en Docker, SIN RED (--network none) y con los datos en memoria (tmpfs); el respaldo se monta de solo lectura.
    3. RESTAURA el respaldo con pg_restore (--no-owner --no-acl) en una base nueva y cuenta los errores.
    4. Cuenta las filas de CADA tabla restaurada y las compara con "filas_por_tabla" del manifiesto (deben coincidir exactamente).
    5. Comprueba que existen los objetos que necesita el hotfix: tablas y columnas, idx_ventas_cotizacion_unica, cartera_venta_id_unique,
       ventas_numero_venta_seq y la funcion registrar_abono_cartera_atomico. Ejecuta el prechequeo de solo lectura del hotfix sobre la copia
       (el hotfix se podria instalar tal cual sobre ese esquema).
    6. Elimina el contenedor y no deja datos en disco. La evidencia (sin datos de clientes, solo conteos y nombres de objetos) va a
       %USERPROFILE%\LaCava-evidencia-local\verificacion-respaldo\ (nunca se sobrescribe).
  Uso:  powershell -ExecutionPolicy Bypass -File .\VERIFICAR-RESPALDO-RESTAURANDO-LOCAL.ps1 -Respaldo <ruta\al\respaldo.dump>
  Codigos de salida: 0 respaldo restaurado y verificado - 1 Docker no disponible - 2 archivo, manifiesto o ruta no validos - 3 la restauracion o
    las comprobaciones NO cumplen (no usar ese respaldo como punto de vuelta atras)
#>
param(
  [Parameter(Mandatory = $true)][string]$Respaldo,
  [string]$Manifiesto,
  [string]$DockerExe = 'docker',
  [string]$Imagen = 'postgres:17',
  [string]$Evidencia = (Join-Path $env:USERPROFILE 'LaCava-evidencia-local\verificacion-respaldo')
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
function Fallar($codigo, $msg) { Write-Host ''; Write-Host $msg -ForegroundColor Red; exit $codigo }
if (-not (Get-Command $DockerExe -ErrorAction SilentlyContinue)) { Fallar 1 'No se encontro Docker. Abre Docker Desktop y vuelve a ejecutar.' }
$ErrorActionPreference = 'Continue'; $null = & $DockerExe info --format '{{.ServerVersion}}' 2>$null; $dockerOk = ($LASTEXITCODE -eq 0); $ErrorActionPreference = 'Stop'
if (-not $dockerOk) { Fallar 1 'Docker Desktop no esta en marcha. Abrelo y vuelve a ejecutar.' }
if (-not (Test-Path -LiteralPath $Respaldo -PathType Leaf)) { Fallar 2 'No se encontro el respaldo en esa ruta.' }
$Respaldo = [IO.Path]::GetFullPath($Respaldo); $nombre = [IO.Path]::GetFileName($Respaldo); $carpeta = [IO.Path]::GetDirectoryName($Respaldo)
if (-not $Manifiesto) {
  $c = Get-ChildItem -LiteralPath $carpeta -Filter 'MANIFIESTO*.txt' -File -ErrorAction SilentlyContinue | Where-Object { (Get-Content -LiteralPath $_.FullName -Encoding UTF8) -contains ('archivo: ' + $nombre) } | Select-Object -First 1
  if ($c) { $Manifiesto = $c.FullName }
}
if (-not $Manifiesto -or -not (Test-Path -LiteralPath $Manifiesto -PathType Leaf)) { Fallar 2 'No se encontro el manifiesto de este respaldo (MANIFIESTO*.txt con "archivo: <nombre>") junto al archivo.' }
$m = @(Get-Content -LiteralPath $Manifiesto -Encoding UTF8)
$hashManifiesto = ($m | Where-Object { $_ -like 'sha256: *' } | Select-Object -First 1); if ($hashManifiesto) { $hashManifiesto = $hashManifiesto.Substring(8).Trim().ToLower() }
$tamManifiesto = ($m | Where-Object { $_ -like 'tamano_bytes: *' } | Select-Object -First 1); if ($tamManifiesto) { $tamManifiesto = [int64]$tamManifiesto.Substring(14).Trim() }
$esperadas = [ordered]@{}
foreach ($l in $m) { if ($l -match '^  ([A-Za-z0-9_]+)\|(\d+)$') { $esperadas[$Matches[1]] = [int64]$Matches[2] } }
if (-not $hashManifiesto -or $esperadas.Count -lt 5) { Fallar 2 'El manifiesto no trae sha256 ni "filas_por_tabla".' }

$resultados = New-Object System.Collections.ArrayList
function Marca([string]$nombreCheck, [bool]$ok, [string]$detalle) { [void]$resultados.Add([pscustomobject]@{ nombre = $nombreCheck; ok = $ok; detalle = $detalle }); Write-Host (($(if ($ok) { '  OK    ' } else { '  FALLA ' })) + $nombreCheck + $(if ($detalle) { ' - ' + $detalle } else { '' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' }) }

Write-Host ('Verificando por restauracion local: ' + $nombre)
$hash = (Get-FileHash -LiteralPath $Respaldo -Algorithm SHA256).Hash.ToLower(); $tam = (Get-Item -LiteralPath $Respaldo).Length
Marca 'SHA-256 del respaldo coincide con el manifiesto' ($hash -eq $hashManifiesto) ($hash.Substring(0, 16) + '...')
if ($tamManifiesto) { Marca 'Tamano coincide con el manifiesto' ($tam -eq $tamManifiesto) ("$tam bytes") }

$cont = 'lacava-verif-respaldo-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$errRestore = @(); $totalErrRestore = 0; $filas = @{}; $objetos = @{}; $prechequeo = @()
function Dk([string[]]$a) { $ErrorActionPreference = 'Continue'; $o = & $DockerExe @a 2>&1; $c = $LASTEXITCODE; $ErrorActionPreference = 'Stop'; return @{ codigo = $c; salida = @($o | ForEach-Object { "$_" }) } }
try {
  $r = Dk @('run', '-d', '--rm', '--name', $cont, '--network', 'none', '--tmpfs', '/var/lib/postgresql/data', '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', '-v', ($carpeta + ':/respaldo:ro'), $Imagen)
  if ($r.codigo -ne 0) { Fallar 1 ('No se pudo iniciar el PostgreSQL desechable: ' + ($r.salida -join ' ')) }
  $listo = $false; for ($i = 0; $i -lt 60 -and -not $listo; $i++) { Start-Sleep -Milliseconds 700; $p = Dk @('exec', $cont, 'pg_isready', '-U', 'postgres', '-h', '127.0.0.1'); if ($p.codigo -eq 0) { Start-Sleep -Seconds 1; $p2 = Dk @('exec', $cont, 'pg_isready', '-U', 'postgres', '-h', '127.0.0.1'); $listo = ($p2.codigo -eq 0) } }
  if (-not $listo) { Fallar 3 'El PostgreSQL desechable no llego a estar listo.' }
  Marca 'PostgreSQL 17 desechable iniciado SIN RED' $true 'contenedor temporal, datos en memoria'
  $null = Dk @('exec', $cont, 'psql', '-U', 'postgres', '-h', '127.0.0.1', '-v', 'ON_ERROR_STOP=1', '-c', 'CREATE DATABASE restaurada')
  # roles que el esquema public suele nombrar (politicas, permisos); no tienen privilegios ni datos
  $null = Dk @('exec', $cont, 'psql', '-U', 'postgres', '-h', '127.0.0.1', '-d', 'restaurada', '-c', "DO `$`$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END `$`$; DO `$`$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END `$`$; DO `$`$ BEGIN CREATE ROLE service_role NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END `$`$;")
  $null = Dk @('exec', $cont, 'psql', '-U', 'postgres', '-h', '127.0.0.1', '-d', 'restaurada', '-c', 'DROP SCHEMA public CASCADE')   # el respaldo trae su propio esquema public
  $rs = Dk @('exec', $cont, 'pg_restore', '-U', 'postgres', '-h', '127.0.0.1', '-d', 'restaurada', '--no-owner', '--no-acl', ('/respaldo/' + $nombre))
  $errRestore = @($rs.salida | Where-Object { $_ -match 'error' }); $totalErrRestore = $errRestore.Count
  Marca 'pg_restore terminado sin errores' ($rs.codigo -eq 0 -and $totalErrRestore -eq 0) ('codigo ' + $rs.codigo + ', mensajes de error: ' + $totalErrRestore)
  # filas por tabla (solo conteos)
  $q = "SELECT table_name || '|' || (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.' || quote_ident(table_name), false, true, '')))[1]::text FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1"
  $c = Dk @('exec', $cont, 'psql', '-U', 'postgres', '-h', '127.0.0.1', '-d', 'restaurada', '-X', '-A', '-t', '-c', $q)
  foreach ($l in $c.salida) { if ($l -match '^([a-z0-9_]+)\|(\d+)$') { $filas[$Matches[1]] = [int64]$Matches[2] } }
  $dif = @(); foreach ($t in $esperadas.Keys) { if (-not $filas.ContainsKey($t)) { $dif += ($t + ': no restaurada (esperadas ' + $esperadas[$t] + ')') } elseif ($filas[$t] -ne $esperadas[$t]) { $dif += ($t + ': ' + $filas[$t] + ' restauradas, ' + $esperadas[$t] + ' esperadas') } }
  Marca ('Filas de las ' + $esperadas.Count + ' tablas del manifiesto, una por una') ($dif.Count -eq 0) ($(if ($dif.Count) { $dif -join ' ; ' } else { 'todas coinciden (total ' + (($esperadas.Values | Measure-Object -Sum).Sum) + ' filas)' }))
  $extra = @($filas.Keys | Where-Object { -not $esperadas.Contains($_) -and $filas[$_] -gt 0 })
  if ($extra.Count) { Marca 'Tablas con filas que el manifiesto no lista' $false ($extra -join ', ') }
  # objetos que necesita el hotfix
  $qo = @"
SELECT 'OBJ|idx_ventas_cotizacion_unica|' || EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND indexname='idx_ventas_cotizacion_unica');
SELECT 'OBJ|cartera_venta_id_unique|' || EXISTS (SELECT 1 FROM pg_constraint WHERE conname='cartera_venta_id_unique');
SELECT 'OBJ|ventas_numero_venta_seq|' || (to_regclass('public.ventas_numero_venta_seq') IS NOT NULL);
SELECT 'OBJ|registrar_abono_cartera_atomico|' || EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='registrar_abono_cartera_atomico');
SELECT 'OBJ|columnas_que_faltan|' || COALESCE((SELECT string_agg(t || '.' || c, ',') FROM (VALUES ('cotizaciones','id'),('cotizaciones','id_licencia'),('cotizaciones','estado'),('cotizaciones','items'),('cotizaciones','venta_id'),('cotizaciones','updated_at'),('cotizaciones','cliente_nombre'),('cotizaciones','cliente_whatsapp'),('ventas','cotizacion_id'),('ventas','direccion_entrega'),('ventas','detalle_entrega'),('ventas','abono'),('ventas','saldo_pendiente'),('ventas','fecha_vencimiento_cartera'),('ventas','puntos_ganados'),('ventas','cliente_whatsapp'),('detalle_ventas','es_unidad'),('detalle_ventas','uds_empaque'),('detalle_ventas','prod_id'),('inventario','stock'),('inventario','uds_sueltas'),('inventario','uds_empaque'),('inventario','id_licencia'),('inventario','nombre'),('clientes_frecuentes','id_licencia'),('cartera','venta_id'),('cartera','fecha_creacion'),('cartera_abonos','medio_pago'),('cartera_abonos','registrado_por')) x(t,c) WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=x.t AND column_name=x.c)), 'ninguna');
SELECT 'OBJ|hotfix_ya_instalado|' || EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='convertir_cotizacion_atomica');
"@
  $o = Dk @('exec', $cont, 'psql', '-U', 'postgres', '-h', '127.0.0.1', '-d', 'restaurada', '-X', '-A', '-t', '-c', $qo)
  foreach ($l in $o.salida) { if ($l -match '^OBJ\|([^|]+)\|(.*)$') { $objetos[$Matches[1]] = $Matches[2] } }
  foreach ($k in @('idx_ventas_cotizacion_unica', 'cartera_venta_id_unique', 'ventas_numero_venta_seq', 'registrar_abono_cartera_atomico')) { Marca ('Objeto restaurado: ' + $k) ($objetos[$k] -eq 'true') }
  Marca 'Columnas que necesita el hotfix' ($objetos['columnas_que_faltan'] -eq 'ninguna') $objetos['columnas_que_faltan']
  Write-Host ('  (informativo) el hotfix ya estaba instalado en el respaldo: ' + $objetos['hotfix_ya_instalado'])
  # una restauracion que se puede VOLVER A USAR: consultas reales sobre la copia
  $uso = Dk @('exec', $cont, 'psql', '-U', 'postgres', '-h', '127.0.0.1', '-d', 'restaurada', '-X', '-A', '-t', '-c', "SELECT 'USO|' || (SELECT count(*) FROM public.ventas) || '|' || (SELECT count(*) FROM public.detalle_ventas WHERE venta_id IN (SELECT id FROM public.ventas)) || '|' || (SELECT count(*) FROM public.cartera c WHERE EXISTS (SELECT 1 FROM public.ventas v WHERE v.id = c.venta_id))")
  $usoL = ($uso.salida | Where-Object { $_ -like 'USO|*' } | Select-Object -First 1)
  Marca 'La copia restaurada es consultable: ventas, detalles y carteras enlazan entre si' ([bool]$usoL) ($usoL)
} finally {
  $ErrorActionPreference = 'Continue'; $null = & $DockerExe rm -f $cont 2>&1; $ErrorActionPreference = 'Stop'
}
$fallos = @($resultados | Where-Object { -not $_.ok })
$dir = Join-Path $Evidencia ('verificacion-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')); New-Item -ItemType Directory -Path $dir -Force | Out-Null
$texto = (@('EVIDENCIA: VERIFICACION DE UN RESPALDO RESTAURANDOLO EN LOCAL (sin datos de clientes, host, usuario ni URLs)', ('fecha_local: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')), ('respaldo: ' + $nombre), ('sha256: ' + $hash), ('tamano_bytes: ' + $tam), ('manifiesto: ' + [IO.Path]::GetFileName($Manifiesto)),
    ('mensajes_de_error_de_pg_restore: ' + $totalErrRestore)) + @($errRestore | Select-Object -First 15 | ForEach-Object { '  ' + $_ }) + @('comprobaciones:') + @($resultados | ForEach-Object { '  ' + $(if ($_.ok) { 'OK    ' } else { 'FALLA ' }) + $_.nombre + $(if ($_.detalle) { ' - ' + $_.detalle } else { '' }) }) +
  @('filas_restauradas_por_tabla:') + @($filas.Keys | Sort-Object | ForEach-Object { '  ' + $_ + '|' + $filas[$_] }) + @(('dictamen: ' + $(if ($fallos.Count -eq 0) { 'RESPALDO RESTAURADO Y VERIFICADO' } else { 'EL RESPALDO NO CUMPLE (' + $fallos.Count + ' comprobaciones fallaron)' })), '')) -join "`n"
$ruta = Join-Path $dir 'VERIFICACION-RESPALDO.txt'
$fs = [IO.File]::Open($ruta, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write); try { $b = (New-Object System.Text.UTF8Encoding $false).GetBytes($texto); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
Write-Host ''; Write-Host ('Evidencia: ' + $ruta)
if ($fallos.Count -gt 0) { Fallar 3 ('EL RESPALDO NO CUMPLE: ' + $fallos.Count + ' comprobaciones fallaron. No lo uses como punto de vuelta atras.') }
Write-Host 'RESPALDO RESTAURADO Y VERIFICADO.' -ForegroundColor Green
exit 0
