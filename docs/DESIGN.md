# c3l design

c3l is a bookkeeper around `c3c fetch`. This file records what was decided and why.

## Findings that shaped the design

Checked against c3c 0.8.6 (nightly 2026-11-01, `fetch` support) and www.c3pkg.eu.

- `c3c fetch` writes only the bare library name into `dependencies`. No version, no lock.
- `c3c` shows `Checksum:` in `fetch-info` but never compares it with the download.
- c3c has no add/remove-dependency command. `c3c project fetch` and `vendor-fetch` use the GitHub vendor releases, not a registry.
- `c3c` rewrites `project.json` in its own format when it adds a dependency.
- c3pkg.eu answers `/info/<ns>/<name>` and `/download/<ns>/<name>@<ver>` as in the protocol, but has **no `/index.json`**, so `c3c fetch-list` fails there. It offers `GET /search?q=&tag=` instead. `c3l search` uses that and falls back to `fetch-list` on other registries.
- The checksum in c3pkg's `/info` is the SHA-256 of the `.c3l` file. A `.c3l` published there carries `version` and `provides` in its `manifest.json`.
- The registry id is `<namespace>/<name>`; on disk only `<name>.c3l` remains.

## Decisions

1. **c3c installs, c3l keeps the books.** c3l calls `c3c fetch --decompress=no` and never downloads or unpacks a registry library itself. Zip is kept because only a file can be hashed, and a file can be committed like a jar.
2. **`c3l.lock` is the source of truth** for version and checksum. TSV, one line per library, sorted: `name kind source version pin hash`, header `@registry <url>`. Greppable without `jq`, stable diffs.
3. **Always fetch an explicit version.** c3l resolves `latest` itself from `fetch-info` and passes `ns/name@version` to c3c. No race between info and download, and sync can ask for an old version.
4. **Fail closed.** A checksum mismatch rolls back and exits 1. Without a registry checksum c3l warns and records the file (trust on first use).
5. **Transactions.** Before each install the old library file and `project.json` are copied away and restored on any failure. `update` can therefore never leave a project without its library.
6. **c3l reads the project only through `c3c project view`** and edits `project.json` in exactly one place: `deps_edit`, needed for `remove` and git sources, because c3c has no command for it. `deps_edit` is a small tokenizer (strings, `//` and `/* */` comments, nesting depth), changes only the top-level `dependencies` array, and its result is verified with `c3c project view`. It works for `project.json5`.
7. **Git sources are first-class but pinned by commit.** Tags can move, commits cannot. The tag is resolved to a commit (annotated tags peeled) via `git ls-remote`; the library is built with `git archive` of that commit (no `.git/`, honours `export-ignore`). The library name comes from `manifest.json` `provides`, not from the repository name. Submodules are not included (warned).
8. **Names are global.** `raylib/raylib` and `other/raylib` both become `raylib.c3l`; c3l refuses the second.
9. **Registry resolution:** `--registry` > `$C3L_REGISTRY` > `@registry` in the lockfile > `https://www.c3pkg.eu`. The lock stores it so a checkout needs no flags.
10. **Bash, one file.** Smallest step from 0.x, no build, works where c3c works. Needs no `jq`. The lock format and commands are language-neutral, so a rewrite (for example in C3) stays possible. Bash 3.2 compatible by construction (no associative arrays, no `sort -V`), but only tested with bash 5.2.
11. **semver in bash** follows semver 2.0 precedence (pre-releases sort below releases). `outdated` and `update` only move to a strictly higher version. Where the registry's `latest` is trusted (protocol), c3l still refuses to propose an older or equal one.

## Not done (yet)

- **Transitive dependencies.** The `manifest.json` inside a `.c3l` lists per-target `dependencies`; c3l does not resolve them.
- **Reproducible zips for git sources.** The hash of a `git archive` zip is stored but only informational; the commit is the pin.
- **Cross-platform registry targets.** `targets` in `fetch-info` are not checked against the host.
- **Parsing `fetch-info` text.** The output format of c3c is documented in the protocol but not a stable API. The parsers are three small functions (`info_*`); `test/run.sh` exercises them against the real c3c, so a format change fails the tests.
- **Private registries with authentication.** `c3c fetch` has no auth option.

## Upstream

If c3c adds a lockfile and checksum verification itself, c3l becomes unnecessary. Until then
the lock format and the verify-and-roll-back flow here are a working prototype of that feature.
