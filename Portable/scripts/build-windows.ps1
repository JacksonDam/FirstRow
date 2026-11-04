# Builds First Row for Windows into dist\windows\FirstRow.
# Needs Swift 6.4 for Windows and Visual Studio's C++ build tools (for lib.exe), run from a
# "Developer PowerShell for VS" prompt. SDL 3 and libmpv are downloaded on the first run.
param(
    [ValidateSet("x64", "arm64")] [string] $Arch = "x64",
    [string] $SdlVersion = "3.4.2"
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\..\.."
$deps = Join-Path $root ".build\windows-deps\$Arch"
New-Item -ItemType Directory -Force -Path $deps | Out-Null

# SDL 3: the official Visual C++ development package.
$sdl = Join-Path $deps "SDL3-$SdlVersion"
if (-not (Test-Path $sdl)) {
    $zip = Join-Path $deps "sdl.zip"
    Invoke-WebRequest "https://github.com/libsdl-org/SDL/releases/download/release-$SdlVersion/SDL3-devel-$SdlVersion-VC.zip" -OutFile $zip
    Expand-Archive $zip -DestinationPath $deps -Force
}

# libmpv: the newest development build from mpv-winbuild-cmake, with an import library made
# from its .def file so the Visual C++ linker can use it.
$mpv = Join-Path $deps "mpv"
if (-not (Test-Path (Join-Path $mpv "mpv.lib"))) {
    $mpvArch = if ($Arch -eq "x64") { "x86_64" } else { "aarch64" }
    $release = Invoke-RestMethod "https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -like "mpv-dev-$mpvArch-*.7z" -and $_.name -notlike "*v3*" } | Select-Object -First 1
    $archive = Join-Path $deps $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $archive
    New-Item -ItemType Directory -Force -Path $mpv | Out-Null
    & 7z x $archive "-o$mpv" -y | Out-Null
    $def = Get-ChildItem $mpv -Recurse -Filter "*.def" | Select-Object -First 1
    $machine = if ($Arch -eq "x64") { "X64" } else { "ARM64" }
    & lib.exe "/def:$($def.FullName)" "/name:libmpv-2.dll" "/out:$(Join-Path $mpv 'mpv.lib')" "/machine:$machine" | Out-Null
}

$sdlInclude = Join-Path $sdl "include"
$sdlLib = Join-Path $sdl "lib\$Arch"
$mpvInclude = Join-Path $mpv "include"

Push-Location $root
try {
    swift build -c release --product FirstRow `
        -Xcc "-I$sdlInclude" -Xcc "-I$mpvInclude" `
        -Xlinker "/LIBPATH:$sdlLib" -Xlinker "/LIBPATH:$mpv" `
        -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup
    if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
} finally {
    Pop-Location
}

$out = Join-Path $root "dist\windows\FirstRow"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $out "Resources") | Out-Null
Copy-Item (Join-Path $root ".build\release\FirstRow.exe") (Join-Path $out "First Row.exe")
Copy-Item (Join-Path $sdlLib "SDL3.dll") $out
Get-ChildItem $mpv -Recurse -Filter "libmpv-2.dll" | Select-Object -First 1 | Copy-Item -Destination $out
# The Swift runtime the app was built against.
$runtime = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory | Sort-Object Name -Descending | Select-Object -First 1
if ($runtime) { Copy-Item (Join-Path $runtime.FullName "usr\bin\*.dll") $out }
foreach ($folder in "Assets.xcassets", "Sounds", "ScreenSaverDefaultPhotos", "Videos") {
    $source = Join-Path $root "firstrow\$folder"
    if (Test-Path $source) { Copy-Item $source (Join-Path $out "Resources") -Recurse }
}
Write-Host "Built $out"
