# Bundled PCRE2

GraphQLite compiles PCRE2's 8-bit interpreter into the extension and CLI. Python
and Rust distributions embed that same extension, with no system PCRE2 runtime
dependency. JIT, the POSIX wrapper, command-line utilities, and tests are omitted.
The Unicode tables and default C-locale character tables are included.

- Version: **10.49**
- Official release: <https://github.com/PCRE2Project/pcre2/releases/tag/pcre2-10.49>
- Tag commit: `6f9d7c1373262c541324a16a358785b33ef116cf`
- Source archive: <https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.bz2>
- Archive SHA256: `53c156e1ba416a20da8e65395daa132da0d80e76910424caca3fcdae7831d384`
- License: [LICENCE.md](LICENCE.md), `BSD-3-Clause WITH PCRE2-exception`.
  Preserve this file when distributing source or binaries. Copies are packaged
  with the Python and Rust bindings as `LICENSE-PCRE2`; standalone extension
  and CLI distributions must also include it.

The selected upstream source and header files are unmodified. `pcre2.h` and
`pcre2_chartables.c` are copies of the upstream generic/distribution files.
`config.h` is GraphQLite's portable configuration; it includes the unmodified
upstream `config.h.generic`. Only the upstream library objects use hidden
visibility, to avoid exporting PCRE2 symbols from the SQLite extension.

To reproduce the vendored files:

```sh
curl -fLO https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.bz2
python3 vendor/pcre2/vendor.py pcre2-10.49.tar.bz2
angreal build extension
angreal test unit
angreal test functional
```

The script verifies the archive checksum before writing and copies the
`COMMON_SOURCES` list from upstream's `Makefile.am`, plus generic headers,
character tables, license and manual-build instructions. It does not overwrite
GraphQLite's configuration or documentation. To update PCRE2, update the version,
archive checksum and commit pin together, review `NON-AUTOTOOLS-BUILD` and the
generic configuration for new defaults, remove obsolete upstream files, and
repeat the regex, unit and functional suites on the supported build platforms.

The matcher uses UTF-8, whole-string matching, and ASCII shorthand classes
(`\w`, `\d`, `\s`) by default. It intentionally does not enable UCP globally.
Matching errors, including invalid UTF-8 and resource limits, are surfaced as
errors rather than false results. The interpreter heap limit is 64 MiB per
match; the upstream finite backtracking and depth limits also apply.
