#!/usr/bin/env python3
"""Reproduce the selected unmodified PCRE2 files from the pinned release tarball.

Usage: python3 vendor/pcre2/vendor.py /path/to/pcre2-10.49.tar.bz2
No build-time downloads or installed PCRE2 libraries are required.
"""
import hashlib
from pathlib import Path
import re
import sys
import tarfile

VERSION = "10.49"
SHA256 = "53c156e1ba416a20da8e65395daa132da0d80e76910424caca3fcdae7831d384"
archive = Path(sys.argv[1])
if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
    raise SystemExit("Archive SHA256 does not match the pinned PCRE2 release")
destination = Path(__file__).resolve().parent
prefix = f"pcre2-{VERSION}/"
with tarfile.open(archive) as source:
    def read(name):
        return source.extractfile(prefix + name).read()

    makefile = read("Makefile.am").decode()
    common = makefile.split("COMMON_SOURCES = \\\n", 1)[1].split("\n\n", 1)[0]
    files = {name: Path(name).name for name in re.findall(r"src/\S+", common)}
    files.update({
        "src/pcre2.h.generic": "pcre2.h",
        "src/config.h.generic": "config.h.generic",
        "src/pcre2_chartables.c.dist": "pcre2_chartables.c",
        "LICENCE.md": "LICENCE.md",
        "NON-AUTOTOOLS-BUILD": "NON-AUTOTOOLS-BUILD",
    })
    for original, target in files.items():
        (destination / target).write_bytes(read(original))
    repository = destination.parent.parent
    for target in ("bindings/rust/LICENSE-PCRE2",
                   "bindings/python/src/graphqlite/LICENSE-PCRE2"):
        (repository / target).write_bytes(read("LICENCE.md"))
print(f"Restored {len(files)} pinned upstream files; GraphQLite config unchanged.")
