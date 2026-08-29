<#
make_release.ps1 - build the FireRedLeafGreenRecomp windows release zips.

Modeled on the snesrecomp Zelda ALttP release script, adapted for the GBA
MinGW / CMake / Ninja toolchain. This repo ships TWO games, so it produces one
zip per game:

  FireRedRecomp-windows-x64-v<Version>.zip
  LeafGreenRecomp-windows-x64-v<Version>.zip

Ships ONLY zips (never a bare exe; the MinGW exe needs the bundled runtime
DLLs). Each zip contains: <Target>.exe (Release, MinGW, stripped) + the four
runtime DLLs (SDL2.dll, libgcc_s_seh-1.dll, libstdc++-6.dll, libwinpthread-1.dll)
+ README.md.

You supply your own legally-obtained ROM and a GBA BIOS dump (gba_bios.bin) on
first run - the runtime's native picker caches the chosen paths to rom.cfg /
bios.cfg next to the exe. Neither the ROM nor the BIOS is ever redistributed.

Zips land in release-stage\. Publish via gh AFTER the user signs off:

  gh release create v<Version> `
      release-stage\FireRedRecomp-windows-x64-v<Version>.zip `
      release-stage\LeafGreenRecomp-windows-x64-v<Version>.zip

Usage: powershell -File tools\make_release.ps1 -Version 0.0.2
#>
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$BuildDir = 'build-release'
)
$ErrorActionPreference = 'Stop'

$MingwBin = 'C:\msys64\mingw64\bin'
$env:PATH = "$MingwBin;$env:PATH"
$root  = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root $BuildDir
$out   = Join-Path $root 'release-stage'
New-Item -ItemType Directory -Force $out | Out-Null

# Games this repo ships: CMake target -> README title + decomp variant (for the
# ROM SHA-1 surfaced in the README).
$games = @(
  @{ Target = 'FireRedRecomp';   Title = 'Pokemon FireRed';   Variant = 'firered'   },
  @{ Target = 'LeafGreenRecomp'; Title = 'Pokemon LeafGreen'; Variant = 'leafgreen' }
)
$dlls = @('SDL2.dll', 'libgcc_s_seh-1.dll', 'libstdc++-6.dll', 'libwinpthread-1.dll')

# Configure once (Release; dynamic + bundled DLLs). GBARECOMP_ROOT defaults to
# ../gbarecomp (the engine checkout) via this repo's CMakeLists. SDL2 is located
# through the msys2 mingw64 prefix - passed explicitly so a fresh checkout
# configures without relying on auto-detection.
if (-not (Test-Path (Join-Path $build 'CMakeCache.txt'))) {
  & cmake -S $root -B $build -G Ninja `
      -DCMAKE_C_COMPILER="$MingwBin/cc.exe" `
      -DCMAKE_CXX_COMPILER="$MingwBin/c++.exe" `
      -DCMAKE_MAKE_PROGRAM="$MingwBin/ninja.exe" `
      -DCMAKE_BUILD_TYPE=Release "-DCMAKE_CXX_FLAGS_RELEASE=-O1 -DNDEBUG" `
      -DGBARECOMP_BUILD_ORACLE=OFF `
      -DGBARECOMP_MINGW_PREFIX_UNIX="/c/msys64/mingw64" `
      -DSDL2_INCLUDE_DIR="C:/msys64/mingw64/include/SDL2" `
      -DSDL2_LIBRARY="C:/msys64/mingw64/lib/libSDL2.dll.a"
  if ($LASTEXITCODE -ne 0) { throw "configure failed ($LASTEXITCODE)" }
}

foreach ($g in $games) {
  $target = $g.Target
  & cmake --build $build --target $target
  if ($LASTEXITCODE -ne 0) { throw "build failed for $target ($LASTEXITCODE)" }

  $exe = Join-Path $build "$target.exe"
  if (-not (Test-Path $exe)) { throw "expected exe missing: $exe" }
  & "$MingwBin\strip.exe" $exe

  $stageName = "$target-windows-x64-v$Version"
  $stage = Join-Path $out $stageName
  if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
  New-Item -ItemType Directory -Force $stage | Out-Null

  Copy-Item $exe $stage
  foreach ($d in $dlls) { Copy-Item (Join-Path $MingwBin $d) $stage }

  # recomp-ui launcher assets (fonts + img TGAs incl. this variant's box art),
  # staged next to the exe by recomp_target_launcher_ui's POST_BUILD. The
  # launcher loads them from <exe>ssets\ at runtime.
  $assets = Join-Path $build 'assets'
  if (-not (Test-Path (Join-Path $assets 'img'))) {
    throw "recomp-ui launcher assets missing: $assets (build with GBAGAME_RECOMP_UI=ON)"
  }
  Copy-Item $assets -Destination $stage -Recurse

  # Bundle the self-contained tcc overlay toolchain (TinyCC + overlay shim
  # headers) next to the exe so a toolchain-less player box self-heals overlay
  # gaps via tcc (overlay backend auto -> tcc). See gbarecomp/tools/fetch_tcc.ps1.
  $engine = (Resolve-Path (Join-Path $PSScriptRoot '..\gbarecomp')).Path
  & (Join-Path $engine 'tools\fetch_tcc.ps1') -Toolchain (Join-Path $stage 'overlay_toolchain') -EngineRoot $engine

  # ROM SHA-1 from the variant's game.toml (best-effort; for the README only).
  $sha = ''
  $toml = Join-Path $root "variants\$($g.Variant)\game.toml"
  if (Test-Path $toml) {
    $m = Select-String -Path $toml -Pattern '^\s*sha1\s*=\s*"([0-9a-fA-F]+)"' | Select-Object -First 1
    if ($m) { $sha = $m.Matches[0].Groups[1].Value }
  }

  @"
# $($g.Title) - GBA static recompilation (Windows x64)

Release build: an optimized native port. Running ``$target.exe`` opens a picker
for your ROM (and, on first run, your GBA BIOS), then the game window.

Static recompilation turns the game's ARM7TDMI code into native C++ (via the
[gbarecomp](https://github.com/mstan/gbarecomp) framework); the rest of the GBA
(PPU, APU, DMA, timers, BIOS HLE) runs through the framework's runner core.

## How to run

1. Extract this folder (keep the four DLLs next to ``$target.exe``).
2. Run ``$target.exe``. On first launch it prompts for:
   - your legally-obtained **$($g.Title) (USA)** ROM (``.gba``)$(if ($sha) { " - expected SHA-1 ``$sha``" })
   - a **GBA BIOS** dump (``gba_bios.bin``).
   The picked paths are cached to ``rom.cfg`` / ``bios.cfg`` next to the exe;
   save data lands next to the exe.

The ROM and BIOS are **never** redistributed - supply your own dumps.

See the GitHub release notes for what changed in v$Version.
"@ | Out-File (Join-Path $stage 'README.md') -Encoding utf8

  $zip = Join-Path $out "$stageName.zip"
  if (Test-Path $zip) { Remove-Item -Force $zip }
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem

  # ZIP entry names must always use '/', regardless of the host OS.
  # Compress-Archive preserves Windows backslashes, which POSIX extractors
  # treat as literal filename characters rather than directory separators -- so
  # a Linux / Steam Deck / Proton user gets files literally named
  # "assets\fonts\LatoLatin-Regular.ttf" (and "mods\packages\..." where the
  # game ships a mod catalog), the nested trees are never created, and the
  # ImGui launcher finds neither its fonts nor its mods. Write portably here,
  # then verify before anyone can publish it.
  # (Convention ported from snesrecomp/SuperMarioWorldRecomp.)
  $rzStageFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $stage).Path)
  $rzZipFull = [IO.Path]::GetFullPath($zip)
  $rzPrefix = $rzStageFull.TrimEnd('\') + '\'
  $rzFiles = @(Get-ChildItem -LiteralPath $stage -File -Recurse |
      Sort-Object FullName)
  $rzArchive = [IO.Compression.ZipFile]::Open(
      $rzZipFull, [IO.Compression.ZipArchiveMode]::Create)
  try {
      foreach ($rzFile in $rzFiles) {
          $rzFull = [IO.Path]::GetFullPath($rzFile.FullName)
          if (-not $rzFull.StartsWith(
                  $rzPrefix, [StringComparison]::OrdinalIgnoreCase)) {
              throw "Refusing to archive a file outside the release stage: $rzFull"
          }
          $rzName = $rzFull.Substring($rzPrefix.Length).Replace('\', '/')
          if ($rzName.StartsWith('/') -or $rzName -match '(^|/)..(/|$)') {
              throw "Unsafe ZIP entry name: $rzName"
          }
          [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
              $rzArchive, $rzFull, $rzName,
              [IO.Compression.CompressionLevel]::Optimal) | Out-Null
      }
  } finally {
      $rzArchive.Dispose()
  }

  # Read the archive back and reject non-portable entry names outright, so a
  # regression in the writer cannot ship a Windows-only zip again.
  $rzArchive = [IO.Compression.ZipFile]::OpenRead($rzZipFull)
  try {
      $rzBad = @($rzArchive.Entries | Where-Object {
          $_.FullName.Contains('\') -or
          $_.FullName.StartsWith('/') -or
          $_.FullName -match '(^|/)..(/|$)'
      })
      if ($rzBad.Count -ne 0) {
          throw "ZIP contains non-portable entry names: $(
              ($rzBad | ForEach-Object FullName) -join ', ')"
      }
      if ($rzArchive.Entries.Count -ne $rzFiles.Count) {
          throw "ZIP entry count mismatch: expected $($rzFiles.Count), got $(
              $rzArchive.Entries.Count)"
      }
  } finally {
      $rzArchive.Dispose()
  }
  Write-Host "--- $stageName ---"
  Get-ChildItem $stage | Select-Object Name, Length | Out-Host
  Get-Item $zip | Select-Object Name, Length | Out-Host
}
