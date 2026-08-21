#!/usr/bin/env python3
"""import_decomp_symbols.py — GOLD oracle importer (multi-variant).

Generalized form of import_pokefirered_gold.py: works for ANY pret GBA decomp
(pokefirered/leafgreen, pokeruby ruby/sapphire, pokeemerald) by taking the
program name + id on the command line instead of hardcoding FireRed.

SUCCESSOR: gbarecomp/tools/symbol_import/import_decomp_symbols.py is the
shared, engine-side importer (see gbarecomp/docs/SYMBOL_OVERLAY.md). It is
game-agnostic — no CODE_COPY_PAIRS / STACK_CODE_COPIES / REVIEWED_SEEDS
tables — reads link maps as well as ELF section tables, harvests data symbols
from every memory region rather than ROM only, and emits its TOML as a config
OVERLAY so a game's hand-authored game.toml is composed with instead of
replaced. This copy stays in place because the Gen3 games' generated code was
produced by it and migrating them carries its own regen + revalidation cost;
prefer the engine-side importer for new work, and treat the per-game tables
above as the checklist of what a Gen3 migration must reproduce (as explicit
--code-copy-pair arguments and reviewed game.toml entries).

Consumes a byte-matching decomp build's ELF metadata (produced in WSL):

  --syms      readelf -sW <game>.elf   (symbol table; THUMB funcs carry bit0)
  --sections  readelf -SW <game>.elf   (section flags: X = code, else data)
  --rom       the matching .gba         (for identity sha1 + size)

Emits, into --out (default <repo>/symbols):

  <id>.toml                 gba_recompile config: [identity] + extra_func + data_range
  imported_symbols.tsv      addr  mode  name      (STT_FUNC)
  function_boundaries.tsv   start end  mode name  (exact, from st_size)
  imported_data_symbols.tsv addr region name      (STT_OBJECT in ROM)

Why readelf (not nm): readelf's raw st_value keeps bit0 set for THUMB funcs
(nm masks it), and section X-flags give the exact code/data split so the
recompiler doesn't sweep megabytes of .rodata/gfx as code.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import sys

# readelf -sW symbol line:  "  539: 0800080d   56 FUNC   LOCAL  DEFAULT  3 Name"
SYM = re.compile(
    r"^\s*\d+:\s+([0-9A-Fa-f]+)\s+(\d+)\s+(\S+)\s+(\S+)\s+\S+\s+(\S+)\s+(.+?)\s*$"
)
# readelf -SW section line: "  [ 3] .text  PROGBITS  08000000 001000 15f9b4 00  AX 0 0 4"
SEC = re.compile(
    r"^\s*\[\s*\d+\]\s+(\S+)\s+(\S+)\s+([0-9A-Fa-f]+)\s+[0-9A-Fa-f]+\s+"
    r"([0-9A-Fa-f]+)\s+[0-9A-Fa-f]+\s+([A-Za-z]*)"
)

ROM_LO, ROM_HI = 0x08000000, 0x09FFFFFF


def region_for(a: int) -> str:
    if 0x02000000 <= a <= 0x0203FFFF: return "ewram"
    if 0x03000000 <= a <= 0x03007FFF: return "iwram"
    if 0x08000000 <= a <= 0x09FFFFFF: return "rom"
    if 0x00000000 <= a <= 0x00003FFF: return "bios"
    return "other"


def parse_sections(path: pathlib.Path):
    code, data = [], []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = SEC.match(line)
        if not m:
            continue
        name, sectype, addr_s, size_s, flags = m.groups()
        if sectype != "PROGBITS":
            continue
        addr, size = int(addr_s, 16), int(size_s, 16)
        if size == 0 or not (ROM_LO <= addr <= ROM_HI):
            continue
        (code if "X" in flags else data).append((name, addr, addr + size))
    return code, data


def coalesce(ranges):
    out = []
    for _name, s, e in sorted(ranges, key=lambda r: r[1]):
        if out and s <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], e))
        else:
            out.append((s, e))
    return out


def in_ranges(a: int, ranges) -> bool:
    for s, e in ranges:
        if s <= a < e:
            return True
    return False


def parse_symbols(path: pathlib.Path):
    funcs: dict[int, tuple[str, int, str]] = {}
    data: list[tuple[int, int, str]] = []
    by_name: dict[str, tuple[int, int]] = {}   # name -> (raw_value, size)
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = SYM.match(line)
        if not m:
            continue
        value_s, size_s, typ, _bind, ndx, name = m.groups()
        name = name.strip()
        if not name or ndx in ("ABS", "UND", "COM"):
            continue
        value, size = int(value_s, 16), int(size_s)
        by_name.setdefault(name, (value, size))
        if typ == "FUNC":
            real = value & ~1
            mode = "thumb" if (value & 1) else "arm"
            funcs.setdefault(real, (mode, size, name))
        elif typ == "OBJECT" and ROM_LO <= value <= ROM_HI:
            data.append((value, size, name))
    return funcs, data, by_name


# Runtime IWRAM code copies that static discovery CANNOT see (the bytes are
# DMA/CpuSet-copied from ROM to an IWRAM buffer at runtime, then executed
# there). Every pret Gen3 decomp ships the same symbol pair per copy: an IWRAM
# OBJECT buffer (the destination) and the ROM source function. Deriving these
# from the symbol table makes the IRQ dispatcher + sound mixer statically
# recompiled for ALL games (FR/LG/RS/Emerald) instead of self-healing through
# the interpreter — which otherwise drops the SWI-in-IRQ drive-to-completion
# fix and hangs WaitForVBlank. See project_fn_entry_hook_regression /
# FireRed's firered.toml for the history.
#   (buffer_symbol, source_symbol_candidates, default_mode)
# source_symbol_candidates is a tuple tried in order — pret decomps disagree
# on case/spelling for the IRQ entry: pokefirered/leafgreen export it as
# `intr_main` (lowercase), pokeruby/sapphire/emerald as `IntrMain`. Both ship
# the same `IntrMain_Buffer` IWRAM destination object, so only the source name
# differs. Without the right source the IRQ dispatcher self-heals through the
# interpreter on every interrupt (~1-2 bridges/frame) instead of being static.
CODE_COPY_PAIRS = [
    ("IntrMain_Buffer",     ("intr_main", "IntrMain"), "arm"),    # ARM IRQ dispatcher
    ("SoundMainRAM_Buffer", ("SoundMainRAM",),         "thumb"),  # M4A mixer (runs in VBlankIntr)
]


# Code copied to a runtime STACK buffer (no symbol for the destination — it's a
# stack local). The destination address is deterministic for a given boot path
# but not symbol-derivable, so it's keyed per game family. ReadFlashId stack-
# copies the tiny ReadFlash1 helper before reading the flash manufacturer/device
# ID; without it ReadFlash1 self-heals, flash detection fails, gFlashMemoryPresent
# stays FALSE and AgbMain SetMainCallback2(NULL) -> the game never boots (black
# screen). FRLG (FireRed + LeafGreen, both revs) share crt0/boot so the buffer is
# at 0x03007DCC; the SOURCE is each game's own ReadFlash1 symbol (& ~1).
#   id_prefix -> [(source_symbol, runtime_addr, size, mode, name)]
STACK_CODE_COPIES = {
    "firered":   [("ReadFlash1", 0x03007DCC, 0x4, "thumb", "ReadFlash1_stack_Buffer")],
    "leafgreen": [("ReadFlash1", 0x03007DCC, 0x4, "thumb", "ReadFlash1_stack_Buffer")],
}

# REVIEWED_SEEDS — runtime-discovered, human-reviewed dispatch-miss seeds, keyed
# by exact game id. These are CART interior PCs that the static finder can't
# reach because they are only entered by an IRQ/SWI *returning* into the middle
# of an already-generated function (e.g. the WaitForVBlank busy-spin body): the
# interrupted PC is a valid resume point but not a function entry, so dispatch
# misses and the interpreter bridges it. Seeding an [[extra_func]] at each such
# PC makes the recompiler emit a dispatchable entry there → statically recompiled,
# no interpreter bridge. Discovered via the self-heal miss log
# (recomp_master_misses.toml.frag) + live TCP `misses`; merged here (NOT into the
# generated <id>.toml, which is overwritten on re-import — PRINCIPLES.md "Never
# auto-write game.toml" / handoff "durable knowledge goes in the importer").
# BIOS PCs (< 0x4000) do NOT belong here — they go in bios/gba_bios.toml.
#   id -> [(addr, mode, note_tag)]
REVIEWED_SEEDS = {
    "leafgreen_usa": [
        # WaitForVBlank (0x08000890..0x080008BF) busy-spin body — IRQ returns
        # mid-spin; dominant interp load (bridged thousands of times).
        (0x080008AC, "thumb", "WaitForVBlank spin resume"),
        (0x080008AE, "thumb", "WaitForVBlank spin resume"),
        (0x080008B0, "thumb", "WaitForVBlank spin resume"),
        (0x080008B2, "thumb", "WaitForVBlank spin resume"),
        # Other IRQ-return / interior resume points seen at the title screen.
        (0x08004C32, "thumb", "irq-return interior resume"),
        (0x08004C3A, "thumb", "irq-return interior resume"),
        (0x08004C3C, "thumb", "irq-return interior resume"),
        (0x08004C46, "thumb", "irq-return interior resume"),
        (0x080074BA, "thumb", "irq-return interior resume"),
        (0x080074BC, "thumb", "irq-return interior resume"),
        (0x080074C2, "thumb", "irq-return interior resume"),
        (0x0800752A, "thumb", "irq-return interior resume"),
        (0x0800752C, "thumb", "irq-return interior resume"),
        (0x08007530, "thumb", "irq-return interior resume"),
        # m4a sound engine (SoundMain ROM) interior resume points.
        (0x081DD060, "thumb", "m4a interior resume"),
        (0x081DD732, "thumb", "m4a interior resume"),
        (0x081DE85E, "thumb", "m4a interior resume"),
        (0x081DE8AA, "thumb", "m4a interior resume"),
        (0x081E34DA, "thumb", "m4a interior resume"),
        (0x081E34DC, "thumb", "m4a interior resume"),
        (0x081E5E74, "thumb", "m4a interior resume"),
    ],
    # Emerald — reconstructed from a deep gameplay session's self-heal frag
    # (overworld/text/sprite/tilemap engine + m4a + libgcc memcpy/divsi). These
    # are frame-present resume points (the runner yields once/VBlank to present,
    # then re-dispatches R15 mid-function). Seeding makes the exercised ones
    # static; the general case is the interior-resume codegen follow-up.
    "emerald_usa": [
        (0x080008C8, "thumb", "WaitForVBlank+0x1C"),
        (0x080008CA, "thumb", "WaitForVBlank+0x1E"),
        (0x080008CC, "thumb", "WaitForVBlank+0x20"),
        (0x080008CE, "thumb", "WaitForVBlank+0x22"),
        (0x08000A00, "thumb", "AllocInternal+0x48"),
        (0x080013CA, "thumb", "SetBgControlAttributes+0x4A"),
        (0x0800184E, "thumb", "InitBgsFromTemplates+0x66"),
        (0x08001ADE, "thumb", "IsDma3ManagerBusyWithBgCopy+0xA"),
        (0x08001AE8, "thumb", "IsDma3ManagerBusyWithBgCopy+0x14"),
        (0x08001AEA, "thumb", "IsDma3ManagerBusyWithBgCopy+0x16"),
        (0x08001AF2, "thumb", "IsDma3ManagerBusyWithBgCopy+0x1E"),
        (0x08001AFA, "thumb", "IsDma3ManagerBusyWithBgCopy+0x26"),
        (0x08001AFC, "thumb", "IsDma3ManagerBusyWithBgCopy+0x28"),
        (0x08001B2C, "thumb", "IsDma3ManagerBusyWithBgCopy+0x58"),
        (0x08002902, "thumb", "WriteSequenceToBgTilemapBuffer+0xC2"),
        (0x0800292E, "thumb", "WriteSequenceToBgTilemapBuffer+0xEE"),
        (0x0800293C, "thumb", "WriteSequenceToBgTilemapBuffer+0xFC"),
        (0x08002ABC, "thumb", "GetTileMapIndexFromCoords+0x8"),
        (0x08002AF8, "thumb", "CopyTileMapEntry+0xC"),
        (0x08002B06, "thumb", "CopyTileMapEntry+0x1A"),
        (0x08002B46, "thumb", "CopyTileMapEntry+0x5A"),
        (0x08002E84, "thumb", "FillBitmapRect4Bit+0x84"),
        (0x08002E8C, "thumb", "FillBitmapRect4Bit+0x8C"),
        (0x08002EAC, "thumb", "FillBitmapRect4Bit+0xAC"),
        (0x080032B6, "thumb", "InitWindows+0xF6"),
        (0x0800482E, "thumb", "RenderFont+0x16"),
        (0x08004D3A, "thumb", "DecompressGlyphTile+0x12A"),
        (0x08004E9C, "thumb", "CopyGlyphToWindow+0xFC"),
        (0x08004ED6, "thumb", "CopyGlyphToWindow+0x136"),
        (0x08004EE6, "thumb", "CopyGlyphToWindow+0x146"),
        (0x08004EEE, "thumb", "CopyGlyphToWindow+0x14E"),
        (0x08004EF0, "thumb", "CopyGlyphToWindow+0x150"),
        (0x08004F40, "thumb", "CopyGlyphToWindow+0x1A0"),
        (0x08005C14, "thumb", "RenderText+0x460"),
        (0x08006C1A, "thumb", "SortSprites+0xBE"),
        (0x0800716A, "thumb", "ResetOamRange+0x1A"),
        (0x080072CE, "thumb", "AllocSpriteTiles+0x32"),
        (0x080072D2, "thumb", "AllocSpriteTiles+0x36"),
        (0x08007598, "thumb", "ResetAllSprites+0xC"),
        (0x08007654, "thumb", "AnimateSprite+0x14"),
        (0x0800767A, "thumb", "AnimateSprite+0x3A"),
        (0x0800769E, "thumb", "BeginAnim+0x16"),
        (0x08007808, "thumb", "ContinueAnim+0x90"),
        (0x08067A80, "thumb", "ZeroBoxMonData+0xC"),
        (0x08068CC8, "thumb", "CalculateBoxMonChecksum+0x50"),
        (0x0806F996, "thumb", "BlendPalette+0xA"),
        (0x08085EE6, "thumb", "RunFieldCallback+0x46"),
        (0x0808A048, "thumb", "DrawMetatile+0xD0"),
        (0x0808A064, "thumb", "DrawMetatile+0xEC"),
        (0x0808A13C, "thumb", "InitCameraUpdateCallback+0x8"),
        (0x082E00C0, "thumb", "m4aSoundInit+0x50"),
        (0x082E0792, "thumb", "m4aSoundVSyncOff+0x2E"),
        (0x082E18BE, "thumb", "ReadFlashId+0x3E"),
        (0x082E190E, "thumb", "ReadFlashId+0x8E"),
        (0x082E6DCE, "thumb", "AgbRFU_checkID+0x62"),
        (0x082E6DD0, "thumb", "AgbRFU_checkID+0x64"),
        (0x082E7560, "thumb", "__divsi3+0x20"),
        (0x082E7BF8, "thumb", "__umodsi3+0x18"),
        (0x082E93F0, "thumb", "memcpy+0x1C"),
        (0x082E93F2, "thumb", "memcpy+0x1E"),
        (0x082E93F4, "thumb", "memcpy+0x20"),
        (0x082E93F6, "thumb", "memcpy+0x22"),
        (0x082E93F8, "thumb", "memcpy+0x24"),
        (0x082E93FA, "thumb", "memcpy+0x26"),
        (0x082E93FC, "thumb", "memcpy+0x28"),
        (0x082E93FE, "thumb", "memcpy+0x2A"),
    ],
}


def derive_code_copies(by_name: dict[str, tuple[int, int]], game_id: str = ""):
    """Return [(runtime_start, source_start, size, mode, buf_name, src_name)]."""
    out = []
    for buf_sym, src_candidates, mode in CODE_COPY_PAIRS:
        if isinstance(src_candidates, str):
            src_candidates = (src_candidates,)
        buf = by_name.get(buf_sym)
        src = None
        src_sym = None
        for cand in src_candidates:
            src = by_name.get(cand)
            if src:
                src_sym = cand
                break
        if not buf or not src:
            continue
        buf_addr, buf_size = buf
        src_val, _ = src
        out.append((buf_addr, src_val & ~1, buf_size or 0x800, mode,
                    buf_sym, src_sym))
    # Stack code copies (destination not symbol-derivable; keyed by game family).
    for prefix, entries in STACK_CODE_COPIES.items():
        if not game_id.startswith(prefix):
            continue
        for src_sym, rt_addr, size, mode, name in entries:
            src = by_name.get(src_sym)
            if not src:
                continue
            out.append((rt_addr, src[0] & ~1, size, mode, name, src_sym))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--name", required=True,
                    help='program name, e.g. "Pokemon LeafGreen Version (USA)"')
    ap.add_argument("--id", required=True,
                    help='program id, e.g. "leafgreen_usa" (used as <id>.toml)')
    ap.add_argument("--syms", type=pathlib.Path, required=True,
                    help="readelf -sW dump")
    ap.add_argument("--sections", type=pathlib.Path, required=True,
                    help="readelf -SW dump")
    ap.add_argument("--rom", type=pathlib.Path, required=True)
    ap.add_argument("--out", type=pathlib.Path, required=True,
                    help="output symbols/ dir")
    ap.add_argument("--toml", type=pathlib.Path, default=None,
                    help="output config TOML (default <out>/<id>.toml)")
    args = ap.parse_args()
    toml_path = args.toml or (args.out / f"{args.id}.toml")

    for p in (args.syms, args.sections):
        if not p.exists():
            print(f"error: missing {p}", file=sys.stderr)
            return 1

    code_secs, data_secs = parse_sections(args.sections)
    data_ranges = coalesce(data_secs)
    # Carve the ROM header (logo/title) out of .text as data too.
    header = (0x08000004, 0x080000C0)
    all_ranges = coalesce([("hdr", *header)] + [("d", s, e) for s, e in data_ranges])

    print("==> code sections:", [(n, hex(s), hex(e)) for n, s, e in code_secs])
    print("==> data ranges:  ", [(hex(s), hex(e)) for s, e in all_ranges])

    funcs, data, by_name = parse_symbols(args.syms)
    code_copies = derive_code_copies(by_name, args.id)
    print(f"==> code copies derived: {len(code_copies)}")
    for rt, src, sz, mode, bn, sn in code_copies:
        print(f"    {bn} (0x{rt:08X}) <- {sn} (0x{src:08X}) size=0x{sz:X} [{mode}]")
    dropped = [a for a in funcs if in_ranges(a, all_ranges)]
    for a in dropped:
        del funcs[a]
    arm = sum(1 for m, _, _ in funcs.values() if m == "arm")
    print(f"==> functions: {len(funcs)} "
          f"(thumb={len(funcs)-arm} arm={arm}), dropped-in-data={len(dropped)}")
    print(f"==> data OBJECT symbols (ROM): {len(data)}")

    rom_sha1 = rom_size = None
    if args.rom.exists():
        b = args.rom.read_bytes()
        rom_sha1, rom_size = hashlib.sha1(b).hexdigest(), len(b)

    args.out.mkdir(parents=True, exist_ok=True)
    frows = sorted(funcs.items())

    with toml_path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("# Generated by import_decomp_symbols.py from a byte-matching\n")
        fh.write("# pret decomp build (readelf). Do not hand-edit; rerun.\n\n")
        fh.write("[program]\n")
        fh.write(f'name = "{args.name}"\n')
        fh.write(f'id = "{args.id}"\n')
        fh.write("load_address = 0x08000000\n")
        fh.write(f"size = 0x{(rom_size or 0):08X}\n")
        fh.write("entry_pc = 0x08000000\n\n")
        fh.write("[identity]\n")
        fh.write(f'sha1 = "{rom_sha1 or ""}"\n\n')
        # Runtime IWRAM code copies (auto-derived from decomp symbols; static
        # discovery can't see runtime-copied code). Makes the IRQ dispatcher +
        # M4A mixer statically recompiled at their IWRAM addresses.
        for rt, src, sz, mode, bn, sn in code_copies:
            fh.write("[[code_copy]]\n")
            fh.write(f"runtime_start = 0x{rt:08X}\n")
            fh.write(f"source_start = 0x{src:08X}\n")
            fh.write(f"size = 0x{sz:X}\n")
            fh.write(f'name = "{bn}"\n')
            fh.write(f'note = "auto-derived: {sn} copied to IWRAM at runtime"\n\n')
            fh.write("[[extra_func]]\n")
            fh.write(f"addr = 0x{rt:08X}\n")
            fh.write(f'mode = "{mode}"\n')
            fh.write(f'name = "{bn.lower()}_iwram"\n')
            fh.write(f'note = "IWRAM-resident code_copy of {sn}"\n\n')
        # Reviewed dispatch-miss seeds (IRQ/SWI-return interior resume points).
        # Skip any addr that is already a function entry (would duplicate).
        reviewed = REVIEWED_SEEDS.get(args.id, [])
        for addr, mode, tag in reviewed:
            if addr in funcs:
                continue
            fh.write("[[extra_func]]\n")
            fh.write(f"addr = 0x{addr:08X}\n")
            fh.write(f'mode = "{mode}"\n')
            fh.write("resume = true\n")
            fh.write(f'name = "resume_{addr:08x}"\n')
            fh.write(f'note = "reviewed dispatch-miss seed: {tag}"\n\n')
        if reviewed:
            print(f"==> reviewed dispatch-miss seeds emitted: "
                  f"{sum(1 for a,_,_ in reviewed if a not in funcs)}/{len(reviewed)}")
        for s, e in all_ranges:
            fh.write("[[data_range]]\n")
            fh.write(f"start = 0x{s:08X}\n")
            fh.write(f"end = 0x{e:08X}\n")
            fh.write('note = "non-executable ROM section (readelf)"\n\n')
        for addr, (mode, _size, name) in frows:
            fh.write("[[extra_func]]\n")
            fh.write(f"addr = 0x{addr:08X}\n")
            fh.write(f'mode = "{mode}"\n')
            fh.write(f'name = "{name}"\n\n')

    with (args.out / "imported_symbols.tsv").open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("# addr\tmode\tname  (STT_FUNC from byte-matching ELF)\n")
        for addr, (mode, _s, name) in frows:
            fh.write(f"0x{addr:08X}\t{mode}\t{name}\n")
    with (args.out / "function_boundaries.tsv").open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("# start\tend\tmode\tname  (end = start+size-1, exact)\n")
        for addr, (mode, size, name) in frows:
            end = addr + size - 1 if size else 0
            fh.write(f"0x{addr:08X}\t0x{end:08X}\t{mode}\t{name}\n")
    with (args.out / "imported_data_symbols.tsv").open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("# addr\tregion\tname  (STT_OBJECT in ROM)\n")
        for addr, _size, name in sorted(data):
            fh.write(f"0x{addr:08X}\t{region_for(addr)}\t{name}\n")

    print(f"==> wrote {toml_path.name}: {len(frows)} extra_func + "
          f"{len(all_ranges)} data_range")
    print(f"==> sha1={rom_sha1} size=0x{(rom_size or 0):08X}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
