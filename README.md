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
- **One file**: a single bash script. Needs `c3c` with `fetch` (0.8.6 or a nightly), `awk`, `sha256sum` or `shasum`; `git` for git sources.

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
| `add <git-url> [tag]` | install from git (highest semver tag, or the given one) |
| `remove <name>` | remove file, `dependencies` entry and lock line |
| `list` | libraries and state: `ok`, `modified`, `missing`, `untracked` |
| `verify` | check files against the lock, exit 1 on problems |
| `outdated`, `update [--dry-run] [name...]` | newer versions, update them |
| `sync [--frozen]` | restore from the lock; `--frozen` fails if lock and project disagree |
| `search <text\|tag:x>`, `info <ns/name>` | registry lookups |
| `migrate` | convert a c3l 0.x `.c3l.deps` |

Libraries are stored as `.c3l` zip files in the first `dependency-search-paths`
entry. Commit them, or ignore them and run `c3l sync` after cloning.

## Why not just `c3c fetch`?

You can. c3l is for when you also want to know *which* version you have, be
sure it is the *same bytes* everywhere, and update on purpose. What was
decided and why is in [docs/DESIGN.md](docs/DESIGN.md).

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
