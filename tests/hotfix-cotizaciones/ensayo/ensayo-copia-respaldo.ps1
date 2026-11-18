<#
  ENSAYO SOBRE LA COPIA LOCAL DE UN RESPALDO DE PRODUCCION (sin red, base desechable, datos solo en memoria del contenedor).
  Uso: powershell -ExecutionPolicy Bypass -File .\tests\hotfix-cotizaciones\ensayo\ensayo-copia-respaldo.ps1 -Respaldo <archivo.dump> [-Evidencia <carpeta>]
  No se conecta a ninguna base remota. Deja la salida completa en la carpeta de evidencia (fuera del repositorio).
#>
param(
  [Parameter(Mandatory = $true)][string]$Respaldo,
  [string]$Evidencia = (Join-Path $env:USERPROFILE 'LaCava-evidencia-local\ensayo-copia-respaldo')
)
$ErrorActionPreference = 'Stop'
$raiz = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$dump = (Resolve-Path -LiteralPath $Respaldo).Path
$carpetaDump = Split-Path -Parent $dump
$archivo = Split-Path -Leaf $dump
New-Item -ItemType Directory -Force -Path $Evidencia | Out-Null
$salida = Join-Path $Evidencia ('ENSAYO-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$n = 'ensayo-copia-' + (Get-Random)
try {
  docker run -d --rm --name $n --network none -e POSTGRES_PASSWORD=x -v ($raiz + ':/h:ro') -v ($carpetaDump + ':/s:ro') postgres:17 | Out-Null
  for ($i = 0; $i -lt 40; $i++) { docker exec $n pg_isready -U postgres 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep 1 }
  Start-Sleep 3
  docker exec $n psql -U postgres -c 'CREATE ROLE anon NOLOGIN' -c 'CREATE ROLE authenticated NOLOGIN' -c 'CREATE ROLE service_role NOLOGIN' | Out-Null
  $ErrorActionPreference = 'Continue'   # pg_restore avisa de que el esquema public ya existe (inocuo en una base nueva)
  $r = docker exec $n pg_restore -U postgres -d postgres --no-owner ('/s/' + $archivo) 2>&1
  $r | Select-Object -Last 3 | ForEach-Object { "restauracion: $_" }
  $res = docker exec $n psql -U postgres -X -f /h/tests/hotfix-cotizaciones/ensayo/ensayo-copia-respaldo.sql 2>&1 | ForEach-Object { "$_" }
  $res | Out-File -FilePath $salida -Encoding utf8
  $res
  Write-Host ''; Write-Host ('Salida completa: ' + $salida)
} finally {
  docker stop $n 2>$null | Out-Null
}
