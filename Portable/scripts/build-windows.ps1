# Builds First Row for Windows into dist\windows\FirstRow.
# Needs Swift 6.4 for Windows and Visual Studio's C++ build tools (for lib.exe), run from a
# "Developer PowerShell for VS" prompt. SDL 3 and libmpv are downloaded on the first run.
param(
    [ValidateSet("x64", "arm64")] [string] $Arch = "x64",
    # The newest SDL 3 release unless one is named.
    [string] $SdlVersion = "",
    # Includes the test harness's folder overrides, as Debug builds on the Mac do.
    [switch] $Harness
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot\..\.."
$deps = Join-Path $root ".build\windows-deps\$Arch"
New-Item -ItemType Directory -Force -Path $deps | Out-Null

# SDL 3: the official Visual C++ development package.
if (-not $SdlVersion) {
    $SdlVersion = (Invoke-RestMethod "https://api.github.com/repos/libsdl-org/SDL/releases/latest").tag_name -replace "^release-", ""
}
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
    $machine = if ($Arch -eq "x64") { "X64" } else { "ARM64" }
    $def = Get-ChildItem $mpv -Recurse -Filter "*.def" | Select-Object -First 1
    if (-not $def) {
        # No .def in the package: list the DLL's exports to make one.
        $dll = Get-ChildItem $mpv -Recurse -Filter "libmpv-2.dll" | Select-Object -First 1
        $exports = & dumpbin.exe /exports $dll.FullName | Select-String "^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)" | ForEach-Object { $_.Matches[0].Groups[1].Value }
        $defPath = Join-Path $mpv "mpv.def"
        Set-Content $defPath (@("LIBRARY libmpv-2.dll", "EXPORTS") + $exports)
        $def = Get-Item $defPath
    }
    & lib.exe "/def:$($def.FullName)" "/name:libmpv-2.dll" "/out:$(Join-Path $mpv 'mpv.lib')" "/machine:$machine" | Out-Null
}

$sdlInclude = Join-Path $sdl "include"
$sdlLib = Join-Path $sdl "lib\$Arch"
$mpvInclude = Join-Path $mpv "include"

Push-Location $root
# Swift prints warnings on stderr, which Windows PowerShell would otherwise treat as fatal.
$ErrorActionPreference = "Continue"
try {
    $extra = @()
    if ($Harness) { $extra += @("-Xswiftc", "-DFIRSTROW_HARNESS_BUILD") }
    swift build -c release --product FirstRow @extra `
        -Xcc "-I$sdlInclude" -Xcc "-I$mpvInclude" `
        -Xlinker "/LIBPATH:$sdlLib" -Xlinker "/LIBPATH:$mpv" `
        -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup
    if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
} finally {
    Pop-Location
    $ErrorActionPreference = "Stop"
}

$out = Join-Path $root "dist\windows\FirstRow"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $out "Resources") | Out-Null
Copy-Item (Join-Path $root ".build\release\FirstRow.exe") (Join-Path $out "First Row.exe")
Copy-Item (Join-Path $sdlLib "SDL3.dll") $out
Get-ChildItem $mpv -Recurse -Filter "libmpv-2.dll" | Select-Object -First 1 | Copy-Item -Destination $out
# The Swift runtime the app was built against, wherever the installer put it.
# The toolchain's own folder has a swiftCore.dll too, so only a Runtimes folder will do.
$swiftCore = @(cmd /c "where swiftCore.dll 2>nul") | Where-Object { $_ -match "\\Runtimes\\" } | Select-Object -First 1
if (-not $swiftCore) {
    $swiftCore = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes", "$env:ProgramFiles\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName "usr\bin\swiftCore.dll" } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $swiftCore) { throw "The Swift runtime (swiftCore.dll) wasn't found" }
Copy-Item (Join-Path (Split-Path $swiftCore) "*.dll") $out
# The Visual C++ runtime, which a fresh Windows may not have yet.
$crt = if ($env:VCToolsRedistDir) { Get-ChildItem (Join-Path $env:VCToolsRedistDir $Arch) -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue | Select-Object -First 1 }
if (-not $crt) { throw "The Visual C++ runtime wasn't found: run this from a Developer PowerShell" }
Copy-Item (Join-Path $crt.FullName "*.dll") $out
foreach ($folder in "Assets.xcassets", "Sounds", "ScreenSaverDefaultPhotos", "Videos", "Fonts") {
    $source = Join-Path $root "firstrow\$folder"
    if (Test-Path $source) { Copy-Item $source (Join-Path $out "Resources") -Recurse }
}
Write-Host "Built $out"
