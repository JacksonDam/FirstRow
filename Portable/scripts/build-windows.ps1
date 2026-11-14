# Builds First Row for Windows into dist\windows\FirstRow, and packs that folder as
# dist\windows\FirstRow-windows-<x64|arm64>.zip.
# Needs Swift 6.4 for Windows and Visual Studio's C++ build tools (for lib.exe), run from a
# "Developer PowerShell for VS" prompt. SDL 3 and libmpv are downloaded on the first run.
param(
    [ValidateSet("x64", "arm64")] [string] $Arch = "x64",
    # The newest SDL 3 release unless one is named.
    [string] $SdlVersion = "",
    # The mpv release whose libmpv is used.
    [string] $MpvVersion = "0.42.0",
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

# libmpv. First Row's own small build of it, when it has been built (see
# build-libmpv-windows.sh, which builds it from source on a Mac or a Linux machine): mpv with
# what First Row asks of it and nothing else, a third of the size of mpv's own. Otherwise
# mpv's own build of it for Windows, the one under the LGPL ("lgpl" in its name), from a
# named release, so that what goes into First Row is what was looked through. Neither has
# anything in it under the GPL, or anything that reads DVDs or unscrambles them: First Row
# reads an unprotected DVD's files itself (see DVDMenuFeature.swift).
$ownMpv = Join-Path $root "Portable\build\libmpv\$Arch"
$usesOwnMpv = Test-Path (Join-Path $ownMpv "libmpv-2.dll")
if ($usesOwnMpv) {
    $mpv = $ownMpv
} else {
    $mpv = Join-Path $deps "mpv-$MpvVersion-lgpl"
    if (-not (Test-Path $mpv)) {
        $mpvArch = if ($Arch -eq "x64") { "x86_64" } else { "aarch64" }
        $name = "libmpv-v$MpvVersion-$mpvArch-w64-mingw32-lgpl.zip"
        $archive = Join-Path $deps $name
        Invoke-WebRequest "https://github.com/mpv-player/mpv/releases/download/v$MpvVersion/$name" -OutFile $archive
        New-Item -ItemType Directory -Force -Path $mpv | Out-Null
        Expand-Archive $archive -DestinationPath $mpv -Force
    }
}
# An import library is made from the DLL's list of exports, for the Visual C++ linker.
$mpvDll = Get-ChildItem $mpv -Recurse -Filter "libmpv-2.dll" | Select-Object -First 1
$mpvLib = Join-Path $mpv "mpv.lib"
if (-not (Test-Path $mpvLib) -or (Get-Item $mpvLib).LastWriteTime -lt $mpvDll.LastWriteTime) {
    $machine = if ($Arch -eq "x64") { "X64" } else { "ARM64" }
    $exports = & dumpbin.exe /exports $mpvDll.FullName | Select-String "^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)" | ForEach-Object { $_.Matches[0].Groups[1].Value }
    $def = Join-Path $mpv "mpv.def"
    Set-Content $def (@("LIBRARY libmpv-2.dll", "EXPORTS") + $exports)
    & lib.exe "/def:$def" "/name:libmpv-2.dll" "/out:$mpvLib" "/machine:$machine" | Out-Null
}

$sdlInclude = Join-Path $sdl "include"
$sdlLib = Join-Path $sdl "lib\$Arch"
$mpvInclude = Join-Path $mpv "include"

# The program's icon and its name and version, as a resource the linker puts into
# First Row.exe: Explorer, the task bar, Alt+Tab and the window all take the icon from there.
# The icon is put together from the app icon's own pictures: the sizes it has as they are,
# and the sizes in between that Windows asks for (20, 24, 40 and 48 pixels) scaled down
# from the next larger one.
$resources = Join-Path $root ".build\windows-resources"
New-Item -ItemType Directory -Force -Path $resources | Out-Null
$iconSet = Join-Path $root "firstrow\Assets.xcassets\AppIcon.appiconset"
Add-Type -AssemblyName System.Drawing
function Get-IconPicture([int] $Size) {
    $exact = @{ 16 = "icon-mac-16x16.png"; 32 = "icon-mac-32x32.png"; 64 = "icon-mac-32x32@2x.png"; 128 = "icon-mac-128x128.png"; 256 = "icon-mac-256x256.png" }
    if ($exact.ContainsKey($Size)) { return [System.Drawing.Bitmap]::new((Join-Path $iconSet $exact[$Size])) }
    $larger = if ($Size -le 32) { "icon-mac-128x128.png" } else { "icon-mac-256x256.png" }
    $source = [System.Drawing.Bitmap]::new((Join-Path $iconSet $larger))
    $scaled = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($scaled)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.DrawImage($source, [System.Drawing.Rectangle]::new(0, 0, $Size, $Size))
    $graphics.Dispose(); $source.Dispose()
    return $scaled
}
# One picture as an icon file holds it: the 256 pixel one as a PNG, the others as bitmaps
# (blue, green, red, alpha, bottom row first) followed by an unused one-bit mask.
function Get-IconEntry([int] $Size) {
    $picture = Get-IconPicture $Size
    $stream = [System.IO.MemoryStream]::new()
    if ($Size -ge 256) {
        $picture.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    } else {
        $writer = [System.IO.BinaryWriter]::new($stream)
        $maskRow = [int]([math]::Ceiling($Size / 32.0)) * 4
        $writer.Write([uint32]40); $writer.Write([int32]$Size); $writer.Write([int32]($Size * 2))
        $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]0)
        $writer.Write([uint32]($Size * $Size * 4 + $maskRow * $Size))
        $writer.Write([int32]0); $writer.Write([int32]0); $writer.Write([uint32]0); $writer.Write([uint32]0)
        $area = [System.Drawing.Rectangle]::new(0, 0, $Size, $Size)
        $data = $picture.LockBits($area, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $row = [byte[]]::new($Size * 4)
        for ($y = $Size - 1; $y -ge 0; $y--) {
            [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($data.Scan0, $y * $data.Stride), $row, 0, $row.Length)
            $writer.Write($row)
        }
        $picture.UnlockBits($data)
        $writer.Write([byte[]]::new($maskRow * $Size))
        $writer.Flush()
    }
    $picture.Dispose()
    return , $stream.ToArray()
}
$iconSizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$iconEntries = $iconSizes | ForEach-Object { , (Get-IconEntry $_) }
$iconPath = Join-Path $resources "FirstRow.ico"
$iconFile = [System.IO.File]::Create($iconPath)
$iconWriter = [System.IO.BinaryWriter]::new($iconFile)
$iconWriter.Write([uint16]0); $iconWriter.Write([uint16]1); $iconWriter.Write([uint16]$iconSizes.Count)
$offset = 6 + 16 * $iconSizes.Count
for ($index = 0; $index -lt $iconSizes.Count; $index++) {
    $side = if ($iconSizes[$index] -ge 256) { 0 } else { $iconSizes[$index] }
    $iconWriter.Write([byte]$side); $iconWriter.Write([byte]$side); $iconWriter.Write([byte]0); $iconWriter.Write([byte]0)
    $iconWriter.Write([uint16]1); $iconWriter.Write([uint16]32)
    $iconWriter.Write([uint32]$iconEntries[$index].Length); $iconWriter.Write([uint32]$offset)
    $offset += $iconEntries[$index].Length
}
foreach ($entry in $iconEntries) { $iconWriter.Write([byte[]]$entry) }
$iconWriter.Dispose(); $iconFile.Dispose()

# The version Windows shows in the file's properties is the Mac app's.
$versionMatch = Select-String -Path (Join-Path $root "First Row.xcodeproj\project.pbxproj") -Pattern "MARKETING_VERSION = ([0-9.]+);" | Select-Object -First 1
$version = if ($versionMatch) { $versionMatch.Matches[0].Groups[1].Value } else { "0.0.0" }
$versionParts = @($version.Split(".") | ForEach-Object { [int]$_ }) + 0, 0, 0, 0 | Select-Object -First 4
$versionCommas = $versionParts -join ","
Set-Content (Join-Path $resources "FirstRow.rc") -Encoding ASCII @"
1 ICON "FirstRow.ico"
1 VERSIONINFO
FILEVERSION $versionCommas
PRODUCTVERSION $versionCommas
FILEOS 0x40004L
FILETYPE 0x1L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904B0"
        BEGIN
            VALUE "FileDescription", "First Row"
            VALUE "ProductName", "First Row"
            VALUE "FileVersion", "$version"
            VALUE "ProductVersion", "$version"
            VALUE "InternalName", "FirstRow"
            VALUE "OriginalFilename", "First Row.exe"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
"@
$resourceCompiler = @("rc.exe", "llvm-rc.exe") | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $resourceCompiler) { throw "The resource compiler (rc.exe) wasn't found: run this from a Developer PowerShell" }
$compiledResources = Join-Path $resources "FirstRow.res"
Push-Location $resources
try {
    & $resourceCompiler /nologo /fo FirstRow.res FirstRow.rc
    if ($LASTEXITCODE -ne 0) { throw "The icon resource didn't compile" }
} finally {
    Pop-Location
}

Push-Location $root
# Swift prints warnings on stderr, which Windows PowerShell would otherwise treat as fatal.
$ErrorActionPreference = "Continue"
try {
    $extra = @()
    if ($Harness) { $extra += @("-Xswiftc", "-DFIRSTROW_HARNESS_BUILD") }
    # (Without what only a debugger reads, which is most of the program's size otherwise.)
    swift build -c release --product FirstRow -debug-info-format none @extra `
        -Xcc "-I$sdlInclude" -Xcc "-I$mpvInclude" `
        -Xlinker "/LIBPATH:$sdlLib" -Xlinker "/LIBPATH:$mpv" `
        -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup `
        -Xlinker $compiledResources
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
Copy-Item $mpvDll.FullName $out
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
# Of those two runtimes, only the DLLs something here loads stay: the program's, and in turn
# each of theirs. (The rest are for what First Row doesn't use: a debugger's view of a Swift
# program, the parts of Swift and of C++ that nothing in it calls.)
$shipped = @{}
Get-ChildItem $out -Filter *.dll | ForEach-Object { $shipped[$_.Name.ToLower()] = $_.FullName }
$loaded = @{}
$toLookAt = New-Object System.Collections.Queue
$toLookAt.Enqueue((Join-Path $out "First Row.exe"))
while ($toLookAt.Count -gt 0) {
    $imports = & dumpbin.exe /dependents $toLookAt.Dequeue() | Select-String "^\s+(\S+\.dll)\s*$" | ForEach-Object { $_.Matches[0].Groups[1].Value.ToLower() }
    foreach ($name in $imports) {
        if ($shipped.ContainsKey($name) -and -not $loaded.ContainsKey($name)) {
            $loaded[$name] = $true
            $toLookAt.Enqueue($shipped[$name])
        }
    }
}
if (-not $loaded.ContainsKey("swiftcore.dll")) { throw "The program's DLLs couldn't be listed (dumpbin): run this from a Developer PowerShell" }
$shipped.Keys | Where-Object { -not $loaded.ContainsKey($_) } | ForEach-Object { Remove-Item $shipped[$_] }
foreach ($folder in "Assets.xcassets", "Sounds", "ScreenSaverDefaultPhotos", "Videos", "Fonts") {
    $source = Join-Path $root "firstrow\$folder"
    if (Test-Path $source) { Copy-Item $source (Join-Path $out "Resources") -Recurse }
}
# The app icon's own pictures are for the Mac, the iPhone and the Apple TV, and large: here
# the icon is inside First Row.exe.
Get-ChildItem (Join-Path $out "Resources\Assets.xcassets") -Directory | Where-Object { $_.Name -like "*.appiconset" -or $_.Name -like "*.brandassets" } | Remove-Item -Recurse -Force
Get-ChildItem (Join-Path $out "Resources") -Recurse -Force -Filter ".DS_Store" | Remove-Item -Force
# What First Row is made with, and the terms of each part (see Portable\Licenses\README.md).
$licenses = Join-Path $out "Licenses"
New-Item -ItemType Directory -Force -Path $licenses | Out-Null
Copy-Item (Join-Path $root "Portable\Licenses\*") $licenses
Copy-Item (Join-Path $root "Portable\Sources\CPortable\plutovg\LICENSE") (Join-Path $licenses "plutovg.MIT.txt")
Copy-Item (Join-Path $root "Portable\Sources\CPortable\plutovg\FTL.TXT") (Join-Path $licenses "FreeType.FTL.txt")
if ($usesOwnMpv) {
    # (Each part of it has its licence beside the DLL it was built into, and a list of them.)
    Copy-Item (Join-Path $mpv "Licenses\*") $licenses
    Copy-Item (Join-Path $mpv "built-from.txt") (Join-Path $licenses "libmpv.built-from.txt")
} else {
    Copy-Item (Join-Path $mpv "LICENSE.LGPL") (Join-Path $licenses "mpv.LGPL.txt")
}
Write-Host "Built $out"

# The download. 7-Zip packs a zip a little tighter than Windows does, where there is one.
$zip = Join-Path $root "dist\windows\FirstRow-windows-$Arch.zip"
if (Test-Path $zip) { Remove-Item $zip }
$sevenZip = @("7z.exe", "7za.exe") | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
$packed = $false
if ($sevenZip) {
    # (One that only makes its own kind of archive says so, and Windows packs the folder.)
    $ErrorActionPreference = "Continue"
    & $sevenZip a -tzip -mx=9 -mfb=258 -mpass=15 $zip $out *> $null
    $packed = ($LASTEXITCODE -eq 0) -and (Test-Path $zip)
    $ErrorActionPreference = "Stop"
}
if (-not $packed) {
    if (Test-Path $zip) { Remove-Item $zip }
    # (Windows' own tar, which writes a zip any unpacker reads: Windows PowerShell's
    # Compress-Archive puts backslashes in the names inside.)
    $ErrorActionPreference = "Continue"
    & tar.exe -a -c -f $zip -C (Split-Path $out) (Split-Path $out -Leaf) *> $null
    $packed = ($LASTEXITCODE -eq 0) -and (Test-Path $zip)
    $ErrorActionPreference = "Stop"
    if (-not $packed) { Compress-Archive $out $zip -CompressionLevel Optimal }
}
Write-Host ("Packed {0} ({1:N0} MB)" -f $zip, ((Get-Item $zip).Length / 1MB))
