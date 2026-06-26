# Build script for HARROW.
#   .\build.ps1            optimized build (default; voxel meshing wants -o:speed)
#   .\build.ps1 -Dbg       debug build
#   .\build.ps1 -Run       build then launch
#   .\build.ps1 -Package   optimized build + create dist\harrow\ ready to ship
param(
    [switch]$Dbg,
    [switch]$Run,
    [switch]$Package
)

$root = $PSScriptRoot
$shdc = Join-Path $root "tools\sokol-shdc.exe"

# regenerate shaders that are newer than their generated odin file
Get-ChildItem (Join-Path $root "src\shaders") -Filter "*.glsl" | ForEach-Object {
    $out = Join-Path $root ("src\shader_" + $_.BaseName + ".odin")
    if (-not (Test-Path $out) -or $_.LastWriteTime -gt (Get-Item $out).LastWriteTime) {
        Write-Host "shdc: $($_.Name)"
        & $shdc -i $_.FullName -o $out -l hlsl5:glsl430 -f sokol_odin
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }
}

# SDL3.dll next to the exe
$sdl = Join-Path $root "SDL3.dll"
if (-not (Test-Path $sdl)) {
    Copy-Item "C:\odin\dist\vendor\sdl3\SDL3.dll" $sdl
}

$flags = @("-out:harrow.exe", "-subsystem:windows")
if ($Dbg) { $flags += @("-debug") } else { $flags += @("-o:speed") }

& odin build (Join-Path $root "src") @flags
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "build ok -> harrow.exe"

if ($Package) {
    $dist = Join-Path $root "dist\harrow"
    Write-Host "packaging -> $dist"

    # clean and recreate
    if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
    New-Item -ItemType Directory -Force $dist | Out-Null

    Copy-Item (Join-Path $root "harrow.exe") $dist
    Copy-Item (Join-Path $root "SDL3.dll")   $dist
    Copy-Item (Join-Path $root "assets")     (Join-Path $dist "assets") -Recurse

    Write-Host "package ok -> dist\harrow\"
    Write-Host "  harrow.exe"
    Write-Host "  SDL3.dll"
    Write-Host "  assets\"
}

if ($Run) { & (Join-Path $root "harrow.exe") }
