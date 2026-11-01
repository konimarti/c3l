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

- **Lockfile** `c3l.lock`: one line per library (version, SHA-256 or commit). Diff-friendly, commit it.
- **Verified**: the registry's checksum is compared with the downloaded file. A mismatch means rollback, not a warning.
- **Safe**: every install is transactional (library file and `project.json` are restored on failure).
- **Registry**: default [www.c3pkg.eu](https://www.c3pkg.eu); any `c3c fetch` registry works (`--registry`, `$C3L_REGISTRY`, or `@registry` in the lockfile).
- **One file**: a single bash script. Needs `c3c` with `fetch` (0.8.6 or a nightly), `awk`, `sha256sum` or `shasum`; `git` and `unzip` for git sources.

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
| `remove <name>` | remove file, `dependencies` entry and lock line |
| `list` | libraries and state: `ok`, `modified`, `missing`, `untracked` |
| `verify` | check files against the lock, exit 1 on problems |
| `outdated`, `update [--dry-run] [name[@ref]...]` | newer versions, update them; `name@ref` switches to an explicit version, tag, branch, `HEAD` or commit |
| `sync [--frozen]` | restore from the lock; `--frozen` fails if lock and project disagree |
| `search <text\|tag:x>`, `info <ns/name>` | registry lookups |
| `migrate` | convert a c3l 0.x `.c3l.deps` |

Libraries are stored as `.c3l` zip files in the first `dependency-search-paths`
entry. Commit them, or ignore them and run `c3l sync` after cloning.

Options may appear before or after the command:

| | |
|---|---|
| `--registry URL` | registry for this command (overrides `$C3L_REGISTRY` and the lockfile) |
| `--dry-run` | with `update`: print what would change |
| `--frozen` | with `sync`, for CI: fail on lock/project drift, never write the lockfile |
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
