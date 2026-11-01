# c3l

Reproducible dependencies for C3 projects, on top of `c3c fetch`.

`c3c fetch` installs a library. It does not remember which version, does not
check the checksum, and cannot update or remove. **c3l adds exactly that**:

```sh
c3l init app && cd app              # c3c init + c3l.lock
c3l add tonis2/vk                   # c3c fetch, checksum verified, locked
c3l add https://github.com/you/lib  # or straight from git, commit pinned
c3l outdated                        # what is newer?
c3l update                          # update, rolled back on any failure
c3l sync --frozen                   # CI: restore exactly what c3l.lock says
```

- **Lockfile** `c3l.lock`: one line per library (version, SHA-256 or commit, and who needs it). Diff-friendly, commit it.
- **Dependencies of libraries**: `c3l add` also installs what a library declares it needs, once each, cycles included. See [Dependencies](#dependencies).
- **Verified**: the registry's checksum is compared with the downloaded file. A mismatch means rollback, not a warning.
- **Safe**: every install is transactional (library file and `project.json` are restored on failure).
- **Registry**: default [www.c3pkg.eu](https://www.c3pkg.eu); any `c3c fetch` registry works (`--registry`, `$C3L_REGISTRY`, or `@registry` in the lockfile).
- **One file**: a single bash script. Needs `c3c` with `fetch` (0.8.6 or a nightly), `awk`, `sha256sum` or `shasum`; `git` and `unzip` for git sources; `curl`, `tar` and `zip` for publishing.

## Install

```sh
git clone https://github.com/konimarti/c3l && cd c3l
make PREFIX=~/.local install        # or just copy ./c3l into your PATH
```

## Commands

| | |
|---|---|
| `init [name]` | create `c3l.lock` (and a project with `c3c init name`) |
| `add <ns/name[@ver]>` | install from the registry |
| `add <git-url>[@ref]` | install from git. No ref: highest semver tag (HEAD if untagged). `ref` is a tag, a branch, `HEAD`, or a full 40-char commit. Branches and `HEAD` follow the tip on `update`; tags and commits stay pinned |
| `remove <name>` | remove file, `dependencies` entry and lock line; refuses if another library needs it (`--force`) |
| `prune` | remove dependency libraries that nothing needs any more (`--dry-run` to look first) |
| `why <name>` | which libraries require `<name>` |
| `list [--tree]` | libraries and state: `ok`, `modified`, `missing`, `untracked`; `dep` marks libraries pulled in by another; `--tree` shows the dependency graph |
| `verify` | check files against the lock, exit 1 on problems |
| `outdated`, `update [--dry-run] [name[@ref]...]` | newer versions, update them; `name@ref` switches to an explicit version, tag, branch, `HEAD` or commit |
| `sync [--frozen]` | restore from the lock; `--frozen` fails if lock and project disagree |
| `search <text\|tag:x>`, `info <ns/name>` | registry lookups |
| `migrate` | convert a c3l 0.x `.c3l.deps` or a c3po `project.lock.json` |
| `check [dir]`, `pack [dir]`, `publish [dir]` | publish a library to a registry, see [Publishing](#publishing) |

Libraries are stored as `.c3l` zip files in the first `dependency-search-paths`
entry. Commit them, or ignore them and run `c3l sync` after cloning.

Options may appear before or after the command:

| | |
|---|---|
| `--registry URL` | registry for this command (overrides `$C3L_REGISTRY` and the lockfile) |
| `--dry-run` | with `update`: print what would change |
| `--frozen` | with `sync`, for CI: fail on lock/project drift, never write the lockfile |
| `--strict` | with `add`/`update`: a library built for another C3 release or platform, or a dependency cycle, is an error, not a warning |
| `--force` | with `remove`: remove even if another library needs it |
| `--allow-host HOST` | trust a git host named by a library's dependencies (`file` for local paths), see [Dependencies](#dependencies) |
| `--version X.Y.Z`, `--token-file F`, `--description`, `--license`, `--tags`, `--docs-url`, `--git-url`, `--c3-version`, `--output`, `--allow-dirty`, `--no-build`, `--offline`, `--registry-type` | see [Publishing](#publishing) |
| `-h`, `-v` | help, version |

## Works with `c3c fetch` and its registry protocol

c3l does not have its own registry format. It speaks the `c3c fetch` protocol
and calls `c3c` for every registry install, so anything `c3c fetch` can use,
c3l can use, and the other way round.

- **Registry:** a plain HTTP server (or a directory of static files). c3l needs the two requests c3c itself makes:
  `GET /info/<ns>/<name>` (JSON) and `GET /download/<ns>/<name>@<version>` (the `.c3l` zip).
  The URL is passed to c3c as `--fetch-url`; give it without a trailing slash (c3l strips one), a base path such as `https://example.org/c3/v1` works.
- **Version and checksum:** c3l reads `Latest:` and `Checksum: sha256:<hex>` from `c3c fetch-info`, always installs an *explicit* version (c3c does not know `@latest`), and compares the downloaded file with the checksum.
  If a registry publishes no checksum, c3l warns and records the downloaded file (trust on first use).
- **Optional, not required:** `/index.json` (needed only by `c3c fetch-list`) and `GET /search?q=&tag=` (used by `c3l search`, e.g. on www.c3pkg.eu). Without `/search`, `c3l search` falls back to `c3c fetch-list`.
- **Installed like c3c does it:** `<name>.c3l` in the first `dependency-search-paths` entry, `<name>` added to `dependencies`.
  The only difference is that c3l always keeps the zip (`--decompress=no`), because only a file can be hashed.
- **Mixing both tools:** a library installed with plain `c3c fetch` shows up as `untracked` in `c3l list` and is rejected by `c3l sync --frozen` and `c3l verify`, until you run `c3l add <ns/name>@<version>` for it. If `c3c fetch` left an unpacked directory, `c3l add` replaces it with the zip.
- **What c3c does not do and c3l adds:** a lockfile, checksum verification, update, outdated, remove, reproducible restore.
- **Not covered:** `c3c vendor-fetch` and `c3c project fetch` (they use the `c3lang/vendor` GitHub releases, not a registry), and registries that need authentication.

Checked with c3c 0.8.6 (nightly, 2026-11-01) against www.c3pkg.eu and a static
test registry. The protocol is the one implemented by `c3c fetch`, `fetch-list` and `fetch-info`.

## Dependencies

c3c does not install the libraries a library needs: it only lists their names, and
every one of them has to be in your `project.json`. c3l does that work for you.

```sh
c3l add acme/app      # installs app, and whatever app (and its dependencies) declare
c3l list --tree       # app 1.0.0 / dcb 1.0.0 / dcc 1.0.0
c3l why dcc           # dcb requires dcc / app requires dcb
c3l remove app        # then 'c3l prune' removes what nothing needs any more
```

**Where a library declares its dependencies**, in its `manifest.json`:

```json
"vendor": { "c3l": { "requires": [
    { "name": "vk",    "source": "tonis2/vk",                      "version": "1.0.1" },
    { "name": "chess", "source": "https://github.com/me/chess.c3l", "version": "v0.2.0" } ] } }
```

`source` is a registry id or a git URL; `version` is the minimum for registry
libraries, and a tag, branch or commit for git ones (optional). c3c ignores the
`vendor` key. You do not have to write it by hand: `c3l publish` fills it in from
the library's own `c3l.lock` (its direct dependencies, `c3l add` them as usual).
c3l also reads, in this order: that block, **c3po's** `vendor.c3po.sources`, and c3c's
plain `dependencies` names (a name with no source cannot be installed: c3l warns and
`c3l verify` fails until you `c3l add` it).

**Rules**

- *Minimum version selection*, as in Go: if two libraries ask for different versions of a
  third, the highest of those minimums is used, never a newer one by surprise. Different
  *major* versions are an error (library names are global in C3).
- *Flat*: everything goes into `lib/` and `project.json`, which is what c3c needs.
- *Cycles are warnings*, not errors and never a loop: each library is installed once
  (`--strict` makes a cycle, or a library that requires itself, an error).
- *One transaction*: if anything in the graph fails, nothing is changed.
- *Your choice wins*: a library you `add` yourself stays "direct" (never pruned), and
  `name@ref` pins it.
- *Trusted hosts*: a dependency may name any git URL. github.com, codeberg.org and the
  hosts of the git URLs you typed are trusted; for anything else c3l asks (or fails when
  not interactive). Allow a host with `--allow-host HOST` or `$C3L_ALLOWED_HOSTS`. A
  graph over 200 libraries is refused (`$C3L_MAX_DEPS`).
- `sync --frozen` restores the whole graph from `c3l.lock` without resolving anything.

`c3l.lock` stays at `# c3l.lock v1`; each line now ends with `direct` or `dep` and the
names the library requires. Older six-column lines are still read (as `direct`).

### Coming from c3po

[c3po](https://github.com/Ecoral360/c3po) (`project.lock.json`, `vendor.c3po.sources`) and
c3l share the `lib/` layout, so you can switch one project at a time.

- c3l **follows** the dependencies c3po libraries declare in `vendor.c3po.sources`.
- `c3l migrate` reads a `project.lock.json` and locks the same commits (GitHub and
  Codeberg), then `c3l sync` rebuilds the libraries as verified archives.
- c3l never writes c3po's files. Turning c3l state into a c3po lock, or emitting
  `vendor.c3po` on publish, is not implemented.
- c3po has no versions or checksums, only commits, so a migrated library is pinned to a
  commit and `c3l update` follows its tag, branch or HEAD from there.

## Publishing

c3l can publish a library to a registry with an upload API. Today that is
[www.c3pkg.eu](https://www.c3pkg.eu); other registries are one set of functions
(`be_<type>_versions|index|publish`) in the script, selected with `--registry-type`
or detected.

```sh
cd mylib.c3l                       # a library directory (c3c init-lib mylib)
git tag v1.0.0                     # the version comes from the tag
export C3PKG_TOKEN=c3p_...         # or --token-file FILE, or C3L_TOKEN
c3l check                          # everything below, without uploading
c3l publish --description "My library" --license MIT --tags "gpu,vulkan"
```

**What a package is.** A zip with `manifest.json` at its root, whose `provides` is the
package name and whose `version` is the release. c3l builds it (`c3l pack`) from the
git-tracked files (no `.git`), deterministically, and writes the version into the
archive's `manifest.json`. Your repository file is not touched.

**Where the version comes from**, in this order: `--version X.Y.Z`; a semver tag on
`HEAD` (`v1.2.3` or `1.2.3`, the highest if there are several); `version` in
`manifest.json`. If `manifest.json` says something different from the chosen version,
c3l warns and uses the chosen one. Versions are `MAJOR.MINOR.PATCH` or
`MAJOR.MINOR.PATCH-prerelease` and **immutable once published** (no overwrite, no delete).

**What is checked before upload** (`c3l check`): `manifest.json` with `provides`; a valid
name and version; a clean working tree (`--allow-dirty` to override); the library
compiles with `c3c` (`--no-build` to skip); the version is not yet on the registry (and
a warning if it is older than one that is); the first publish has a `--description`.
After the upload c3l downloads the registry's record and compares its SHA-256 with the
file it sent. `--dry-run` stops before the upload.

**Token.** Create it in the registry under Settings, API tokens. c3l reads it from
`--token-file`, `$C3L_TOKEN` or `$C3PKG_TOKEN` (never a command line argument) and sends it
from a private temporary file, so it does not show up in `ps` or in the output.

**Compatibility.** Each upload carries the C3 version it was published with
(`--c3-version`, default: your `c3c`). On `c3l add`, `update` and `info`, c3l reads the
registry's record for that version and warns if it was published for another C3 release
(compared by major.minor, C3 is pre-1.0) or does not list your platform. `--strict` turns
the warning into an error. Registries that do not publish this data are not checked.

**Dependencies of your library:** `c3l add` them in the library (that writes its `c3l.lock`);
`pack` and `publish` copy the direct ones into the archive's `manifest.json` as
`vendor.c3l.requires`. `check` warns about names in `dependencies` that have no source.

**Not covered:** yanking versions, editing package metadata after the first publish, and
registries without an upload API (publishing to those fails with a clear message).

## Why not just `c3c fetch`?

You can. c3l is for when you also want to know *which* version you have, be
sure it is the *same bytes* everywhere, and update on purpose.

## Upgrading from c3l 0.x

0.x cloned a git repository, zipped it (including `.git/`) and edited
`project.json` with `sed`. 1.0 uses `c3c fetch`, builds git libraries with
`git archive`, and reads the project only through `c3c project view`.
Run `c3l migrate` once. `LOCALREPO` is gone; `file://` URLs and `--registry`
cover testing.

## Tests

`make test` runs an offline suite (a static fake registry and local git
repositories). `LIVE=1 make test` adds a smoke test against www.c3pkg.eu.

MIT. See LICENSE.
