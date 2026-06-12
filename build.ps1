# Build script for HARROW.
#   .\build.ps1          optimized build (default; voxel meshing wants -o:speed)
#   .\build.ps1 -Dbg     debug build
#   .\build.ps1 -Run     build then launch
param(
    [switch]$Dbg,
    [switch]$Run
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

if ($Run) { & (Join-Path $root "harrow.exe") }
