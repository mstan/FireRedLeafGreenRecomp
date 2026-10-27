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
  [string]$BuildDir = 'build-release',
  [string]$OutputDir = 'release-stage',
  [string]$EngineRoot = '',
  [string]$RecompUiRoot = '',
  [string]$GeneratedBiosDir = '',
  [ValidateRange(1, 32)][int]$Jobs = 2,
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'

$MingwBin = 'C:\msys64\mingw64\bin'
$env:PATH = "$MingwBin;$env:PATH"
$root  = Split-Path -Parent $PSScriptRoot
$build = if ([IO.Path]::IsPathRooted($BuildDir)) { [IO.Path]::GetFullPath($BuildDir) } else { Join-Path $root $BuildDir }
$out = if ([IO.Path]::IsPathRooted($OutputDir)) { [IO.Path]::GetFullPath($OutputDir) } else { Join-Path $root $OutputDir }
if ([IO.Path]::GetPathRoot($out) -eq 'C:\') { throw 'Release staging must use non-C: storage' }
if (-not $EngineRoot) { $EngineRoot = Join-Path $root 'gbarecomp' }
$engine = (Resolve-Path -LiteralPath $EngineRoot).Path
if (-not $RecompUiRoot) { $RecompUiRoot = Join-Path $root 'recomp-ui' }
$ui = (Resolve-Path -LiteralPath $RecompUiRoot).Path
if (-not $GeneratedBiosDir) { $GeneratedBiosDir = Join-Path $engine 'src/runtime/generated_bios' }
$generatedBiosPath = (Resolve-Path -LiteralPath $GeneratedBiosDir).Path
foreach ($entry in @(@('gbarecomp', $engine), @('recomp-ui', $ui))) {
  $pin = ((git -C $root ls-tree HEAD $entry[0]) -split '\s+')[2]
  $head = (git -C $entry[1] rev-parse HEAD).Trim()
  if ($pin -ne $head) { throw "$($entry[0]) must match pinned commit $pin" }
  if (git -C $entry[1] status --porcelain --untracked-files=no --ignore-submodules=all) {
    throw "$($entry[0]) has uncommitted tracked changes"
  }
}
foreach ($name in @('bios_recompiled.cpp', 'bios_recompiled.h', 'bios_dispatch_table.cpp', 'bios_symbol_map.cpp')) {
  if (-not (Test-Path -LiteralPath (Join-Path $generatedBiosPath $name))) {
    throw "Generated BIOS input missing: $name"
  }
}
$env:TEMP = Join-Path $out '.scratch'
$env:TMP = $env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
$Cmake = Join-Path $MingwBin 'cmake.exe'
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
if (-not $SkipBuild) {
  & $Cmake -S $root -B $build -G Ninja `
      -DCMAKE_C_COMPILER="$MingwBin/cc.exe" `
      -DCMAKE_CXX_COMPILER="$MingwBin/c++.exe" `
      -DCMAKE_MAKE_PROGRAM="$MingwBin/ninja.exe" `
      -DCMAKE_BUILD_TYPE=Release "-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG" `
      "-DGBARECOMP_ROOT=$engine" `
      "-DRECOMP_UI_ROOT=$ui" `
      "-DGBARECOMP_RUNTIME_UI_ROOT=$ui" `
      "-DGBARECOMP_GENERATED_BIOS_DIR=$generatedBiosPath" `
      -DGBARECOMP_BUILD_ORACLE=OFF `
      -DGBARECOMP_MINGW_PREFIX_UNIX="/c/msys64/mingw64" `
      -DSDL2_INCLUDE_DIR="C:/msys64/mingw64/include/SDL2" `
      -DSDL2_LIBRARY="C:/msys64/mingw64/lib/libSDL2.dll.a"
  if ($LASTEXITCODE -ne 0) { throw "configure failed ($LASTEXITCODE)" }
}

foreach ($g in $games) {
  $target = $g.Target
  if (-not $SkipBuild) {
    & $Cmake --build $build --target $target --parallel $Jobs
    if ($LASTEXITCODE -ne 0) { throw "build failed for $target ($LASTEXITCODE)" }
  }

  $exe = Join-Path $build "$target.exe"
  if (-not (Test-Path $exe)) { throw "expected exe missing: $exe" }

  $stageName = "$target-windows-x64-v$Version"
  $stage = Join-Path $out $stageName
  if (Test-Path -LiteralPath $stage) { throw "Release stage already exists: $stage" }
  New-Item -ItemType Directory -Force $stage | Out-Null

  Copy-Item -LiteralPath $exe -Destination $stage
  & "$MingwBin\strip.exe" (Join-Path $stage "$target.exe")
  if ($LASTEXITCODE -ne 0) { throw "strip failed for $target" }
  Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $stage
  foreach ($d in $dlls) { Copy-Item (Join-Path $MingwBin $d) $stage }

  # recomp-ui launcher assets (fonts + img TGAs incl. this variant's box art),
  # staged next to the exe by recomp_target_launcher_ui's POST_BUILD. The
  # launcher loads them from <exe>ssets\ at runtime.
  $assets = Join-Path $build 'assets'
  if (-not (Test-Path (Join-Path $assets 'img'))) {
    throw "recomp-ui launcher assets missing: $assets (build with GBAGAME_RECOMP_UI=ON)"
  }
  Copy-Item $assets -Destination $stage -Recurse

  # Ship only the authored catalog; never copy developer selections or caches.
  $mods = Join-Path $root 'mods/preloaded'
  if (-not (Test-Path -LiteralPath (Join-Path $mods 'packages/pokemon-gen3.enhancement.widescreen/1.0.0/manifest.toml'))) {
    throw "Adaptive Overworld catalog missing: $mods"
  }
  Copy-Item -LiteralPath $mods -Destination (Join-Path $stage 'mods') -Recurse

  # Bundle the self-contained tcc overlay toolchain (TinyCC + overlay shim
  # headers) next to the exe so a toolchain-less player box self-heals overlay
  # gaps via tcc (overlay backend auto -> tcc). See gbarecomp/tools/fetch_tcc.ps1.
  & (Join-Path $engine 'tools\fetch_tcc.ps1') -Toolchain (Join-Path $stage 'overlay_toolchain') -EngineRoot $engine -CacheDir (Join-Path $out ".toolchain-cache-$target")

  # Select the cartridge identity; the first SHA-1 in game.toml is the BIOS.
  $toml = Get-Content -Raw -LiteralPath (Join-Path $root "variants\$($g.Variant)\game.toml")
  $identity = [regex]::Match($toml, '(?ms)^\[identity\]\s*$(.*?)(?=^\[|\z)').Groups[1].Value
  $sha = [regex]::Match($identity, '(?m)^\s*sha1\s*=\s*"([0-9a-fA-F]{40})"').Groups[1].Value
  if (-not $sha) { throw "ROM identity is missing for $($g.Variant)" }

  @"
# $($g.Title) - GBA static recompilation (Windows x64)

Release build: an optimized native port. Running ``$target.exe`` opens a picker
for your ROM (and, on first run, your GBA BIOS), then the game window.

Static recompilation turns the game's ARM7TDMI code into native C++ (via the
[gbarecomp](https://github.com/mstan/gbarecomp) framework); the rest of the GBA
(PPU, APU, DMA and timers) runs through the framework's runner core. The real
GBA BIOS executes through the generated LLE path; supply your own BIOS dump.

## How to run

1. Extract this folder (keep the four DLLs next to ``$target.exe``).
2. Run ``$target.exe``. On first launch it prompts for:
   - your legally-obtained **$($g.Title) (USA)** ROM (``.gba``)$(if ($sha) { " - expected SHA-1 ``$sha``" })
   - a **GBA BIOS** dump (``gba_bios.bin``).
   The picked paths are cached to ``rom.cfg`` / ``bios.cfg`` next to the exe;
   save data lands next to the exe.

The ROM and BIOS are **never** redistributed - supply your own dumps.

## Adaptive Overworld

Open **Mods**, enable **Adaptive Overworld**, choose **Fit to screen**, and apply.
Resize the game window wider or taller to reveal additional scenery and NPCs.
Field menus follow the expanded edges. Battles and unsupported screens stay centered.
Distant NPCs use idle poses; their AI and interaction ranges retain native behavior.
The feature is optional and starts disabled in a fresh extraction.

See the GitHub release notes for what changed in v$Version.
"@ | Out-File (Join-Path $stage 'README.md') -Encoding utf8

  $zip = Join-Path $out "$stageName.zip"
  if (Test-Path -LiteralPath $zip) { throw "Release ZIP already exists: $zip" }
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
          if ($rzName.StartsWith('/') -or $rzName -match '(^|/)\.\.(/|$)') {
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
          $_.FullName -match '(^|/)\.\.(/|$)'
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
