#!/usr/bin/env python3
"""Inspect a PE file: machine type, subsystem, and import table.

Useful to confirm a RustDesk QuickHost build is x64 and statically linked
(no VC++ redistributable / UCRT DLL imports).

Usage:
  python3 tools/pe_deps.py path/to/RustDeskQS-x64.exe
  python3 tools/pe_deps.py app.exe --list-file winpe_modules.txt
  python3 tools/pe_deps.py app.exe --check-crt
"""
import argparse
import os
import struct
import sys

MACHINES = {0x014C: "i386 (x86)", 0x8664: "AMD64 (x64)", 0xAA64: "ARM64", 0x01C4: "ARM"}
SUBSYSTEMS = {1: "Native", 2: "Windows GUI", 3: "Windows Console", 10: "Windows CE"}
CRT_PATTERNS = (
    "vcruntime", "msvcp", "ucrtbase", "concrt", "vccorlib", "msvcr",
    "api-ms-win-crt", "msvcm", "api-ms-win-crt-",
)


def read_cstr(data, off):
    end = data.find(b"\x00", off)
    if end < 0:
        end = len(data)
    return data[off:end].decode("ascii", "replace")


class Pe:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        if len(d) < 0x40 or d[:2] != b"MZ":
            raise ValueError("not an MZ image: %s" % path)
        e_lfanew = struct.unpack_from("<I", d, 0x3C)[0]
        if d[e_lfanew:e_lfanew + 4] != b"PE\x00\x00":
            raise ValueError("PE signature not found")
        coff = e_lfanew + 4
        (self.machine, self.nsections, _, _, _, self.opt_size, self.chars) = struct.unpack_from(
            "<HHIIIHH", d, coff)
        opt = coff + 20
        self.magic = struct.unpack_from("<H", d, opt)[0]
        self.subsystem = struct.unpack_from("<H", d, opt + 68)[0]
        # MajorSubsystemVersion/MinorSubsystemVersion are at offset 48/50
        self.subsys_major, self.subsys_minor = struct.unpack_from("<HH", d, opt + 48)
        if self.magic == 0x20B:  # PE32+
            num_rva = struct.unpack_from("<I", d, opt + 108)[0]
            dd = opt + 112
        else:  # PE32
            num_rva = struct.unpack_from("<I", d, opt + 92)[0]
            dd = opt + 96
        self.import_rva = struct.unpack_from("<I", d, dd + 8)[0] if num_rva > 1 else 0
        self.delay_rva = struct.unpack_from("<I", d, dd + 104)[0] if num_rva > 13 else 0

        self.sections = []
        sec_off = opt + self.opt_size
        for i in range(self.nsections):
            o = sec_off + 40 * i
            name = d[o:o + 8].split(b"\x00", 1)[0].decode("ascii", "replace")
            vsize, va, rsize, raw = struct.unpack_from("<IIII", d, o + 8)
            self.sections.append(dict(name=name, va=va, vsize=vsize, raw=raw, rsize=rsize))

    def rva_to_off(self, rva):
        for s in self.sections:
            span = max(s["vsize"], s["rsize"])
            if s["va"] <= rva < s["va"] + span:
                off = s["raw"] + (rva - s["va"])
                return off if 0 <= off < len(self.data) else None
        return None

    def _read_cstr_rva(self, rva):
        off = self.rva_to_off(rva)
        return None if off is None else read_cstr(self.data, off)

    def imports(self):
        out = []
        if not self.import_rva:
            return out
        off = self.rva_to_off(self.import_rva)
        if off is None:
            return out
        d = self.data
        while True:
            oft, _, _, name_rva, first = struct.unpack_from("<IIIII", d, off)
            if oft == 0 and name_rva == 0 and first == 0:
                break
            dll = self._read_cstr_rva(name_rva) or "?"
            thunk_rva = oft or first
            funcs = []
            t_off = self.rva_to_off(thunk_rva)
            if t_off is not None:
                while True:
                    entry = struct.unpack_from("<Q" if self.magic == 0x20B else "<I", d, t_off)[0]
                    if entry == 0:
                        break
                    if entry & (1 << (63 if self.magic == 0x20B else 31)):
                        funcs.append("#%d" % (entry & 0xFFFF))
                    else:
                        hint_off = self.rva_to_off(entry)
                        funcs.append(read_cstr(d, hint_off + 2) if hint_off is not None else "?")
                    t_off += 8 if self.magic == 0x20B else 4
            out.append((dll, funcs))
            off += 20
        return out

    def delay_imports(self):
        out = []
        if not self.delay_rva:
            return out
        off = self.rva_to_off(self.delay_rva)
        if off is None:
            return out
        d = self.data
        while True:
            # IMAGE_DELAYLOAD_DESCRIPTOR
            (attrs, name_rva, module, iat, int_, bound, unload, ts) = struct.unpack_from("<IIIIIIII", d, off)
            if attrs == 0 and name_rva == 0 and iat == 0:
                break
            out.append(self._read_cstr_rva(name_rva) or "?")
            off += 32
        return out

    @property
    def is_crt_dynamic(self):
        return [d for d, _ in self.imports()
                if any(p in d.lower() for p in CRT_PATTERNS)]


def listfile_deps(path):
    """Parse a module list (one file name per line) as used by WinPE boot.wim."""
    names = set()
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(";") or line.startswith("#"):
                continue
            name = os.path.basename(line.replace("/", "\\").lower())
            if name:
                names.add(name)
    return names


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("exe", help="PE file to inspect")
    ap.add_argument("--list-file", help="compare against a WinPE module list file")
    ap.add_argument("--check-crt", action="store_true",
                    help="exit non-zero if dynamic CRT imports are present")
    ap.add_argument("--symbols", action="store_true", help="also print imported symbols")
    args = ap.parse_args(argv)

    pe = Pe(args.exe)
    dlls = [d for d, _ in pe.imports()]
    size = os.path.getsize(args.exe)

    print("file      : %s" % args.exe)
    print("size      : %.1f KB" % (size / 1024.0))
    print("machine   : %s" % MACHINES.get(pe.machine, "0x%04X" % pe.machine))
    print("format    : %s" % ("PE32+" if pe.magic == 0x20B else "PE32"))
    print("subsystem : %s %d.%d" % (SUBSYSTEMS.get(pe.subsystem, "id=%d" % pe.subsystem),
                                    pe.subsys_major, pe.subsys_minor))
    print("imports   : %s" % (", ".join(dlls) if dlls else "(none)"))
    delay = pe.delay_imports()
    if delay:
        print("delay     : %s" % ", ".join(delay))

    crt = pe.is_crt_dynamic
    if crt:
        print("CRT       : DYNAMIC -> %s" % ", ".join(crt))
    else:
        print("CRT       : static (no vcruntime/msvcp/ucrt import)")

    if args.symbols:
        for dll, funcs in pe.imports():
            print("  %-16s %s" % (dll, ", ".join(funcs) if funcs else "(none)"))

    rc = 0
    if args.check_crt and crt:
        rc = 1

    if args.list_file:
        have = {d.lower() for d in dlls} | {d.lower() for d in delay}
        present = listfile_deps(args.list_file)
        missing = sorted(have - present)
        print("\nAgainst %s:" % args.list_file)
        if missing:
            print("  NOT present in WinPE: %s" % ", ".join(missing))
            rc = rc or 2
        else:
            print("  all imports are satisfied by WinPE module list")
        print("  WinPE list has %d modules, binary needs %d" % (len(present), len(have)))

    return rc


if __name__ == "__main__":
    sys.exit(main())
