#!/usr/bin/env python3
"""Transcode DDS textures in an EA BIG archive to AS66 (ASTC 6x6) DDS overrides.

The output preserves each archive-relative path, so it can be copied into the
Generals data root as loose files that override the original BIG entries.
Only the top mip is emitted for the initial Android implementation.
"""

import argparse
import fnmatch
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

DDS_MAGIC = b"DDS "
ASTC_MAGIC = b"\x13\xab\xa1\x5c"
AS66 = b"AS66"


def read_big_entries(path: Path):
    with path.open("rb") as f:
        if f.read(4) != b"BIGF":
            raise ValueError(f"{path}: not a BIGF archive")
        f.read(4)  # Archive size; unused.
        count = struct.unpack(">I", f.read(4))[0]
        f.read(4)
        entries = []
        for _ in range(count):
            offset, size = struct.unpack(">II", f.read(8))
            name = bytearray()
            while True:
                byte = f.read(1)
                if not byte:
                    raise ValueError(f"{path}: truncated directory")
                if byte == b"\0":
                    break
                name += byte
            entries.append((name.decode("latin-1").replace("\\", "/"), offset, size))
        return entries


def wrap_as66_dds(source_dds: bytes, astc: bytes) -> bytes:
    if len(source_dds) < 128 or source_dds[:4] != DDS_MAGIC:
        raise ValueError("invalid source DDS")
    if len(astc) < 16 or astc[:4] != ASTC_MAGIC:
        raise ValueError("invalid ASTC output")

    block_x, block_y, block_z = astc[4], astc[5], astc[6]
    width = int.from_bytes(astc[7:10], "little")
    height = int.from_bytes(astc[10:13], "little")
    depth = int.from_bytes(astc[13:16], "little")
    if (block_x, block_y, block_z) != (6, 6, 1) or depth != 1:
        raise ValueError(f"unexpected ASTC geometry: block={block_x}x{block_y}x{block_z}, depth={depth}")

    header = bytearray(source_dds[:128])
    struct.pack_into("<I", header, 8, 0x000A1007)  # DDSD_CAPS|HEIGHT|WIDTH|PIXELFORMAT|LINEARSIZE
    struct.pack_into("<I", header, 12, height)
    struct.pack_into("<I", header, 16, width)
    struct.pack_into("<I", header, 20, ((width + 5) // 6) * ((height + 5) // 6) * 16)
    struct.pack_into("<I", header, 24, 0)
    struct.pack_into("<I", header, 28, 1)
    struct.pack_into("<I", header, 80, 0x4)  # DDPF_FOURCC
    header[84:88] = AS66
    for offset in range(88, 108, 4):
        struct.pack_into("<I", header, offset, 0)
    struct.pack_into("<I", header, 108, 0x1000)  # DDSCAPS_TEXTURE
    for offset in range(112, 128, 4):
        struct.pack_into("<I", header, offset, 0)
    return bytes(header) + astc[16:]


def run(args):
    entries = read_big_entries(args.big)
    selected = [e for e in entries if e[0].lower().endswith(".dds") and fnmatch.fnmatch(e[0].lower(), args.match.lower())]
    if args.limit:
        selected = selected[:args.limit]
    print(f"Selected {len(selected)} DDS files from {args.big}")

    args.output.mkdir(parents=True, exist_ok=True)
    with args.big.open("rb") as archive, tempfile.TemporaryDirectory(prefix="generals-astc-") as td:
        temp = Path(td)
        for index, (name, offset, size) in enumerate(selected, 1):
            archive.seek(offset)
            source = archive.read(size)
            source_path = temp / "source.dds"
            rgba_path = temp / "source.png"
            astc_path = temp / "output.astc"
            source_path.write_bytes(source)
            for path in (rgba_path, astc_path):
                path.unlink(missing_ok=True)

            subprocess.run([
                args.ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                "-i", str(source_path), "-frames:v", "1", str(rgba_path)
            ], check=True)
            subprocess.run([
                args.astcenc, "-cl", str(rgba_path), str(astc_path), "6x6",
                f"-{args.quality}", "-decode_unorm8"
            ], check=True, stdout=subprocess.DEVNULL)

            output_path = args.output / Path(name)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(wrap_as66_dds(source, astc_path.read_bytes()))
            print(f"[{index}/{len(selected)}] {name}: {size} -> {output_path.stat().st_size} bytes")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("big", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--match", default="*.dds", help="case-insensitive archive path glob")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--quality", choices=("fastest", "fast", "medium", "thorough", "verythorough", "exhaustive"), default="fast")
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "ffmpeg")
    parser.add_argument("--astcenc", default=os.environ.get("ASTCENC", "astcenc"))
    run(parser.parse_args())


if __name__ == "__main__":
    main()
