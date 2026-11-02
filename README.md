# c3l

Reproducible dependencies for C3 projects, on top of `c3c fetch`.

`c3c fetch` installs a library but does not remember the version, check the
checksum, or update and remove. c3l adds that.

```sh
c3l init app && cd app              # c3c init + c3l.lock
c3l add tonis2/vk                   # install, checksum verified, locked
c3l add https://github.com/you/lib  # or from git, commit pinned
c3l outdated                        # what is newer?
c3l update                          # update, rolled back on any failure
c3l sync --frozen                   # CI: restore exactly what c3l.lock says
```

- `c3l.lock` has one line per library, including where it came from (registry URL or git URL). Commit it.
- Checksum mismatch means rollback, not a warning.
- Every install is transactional: on failure the library file and `project.json` are restored.
- Default registry is [www.c3pkg.eu](https://www.c3pkg.eu). Pick another for `add` with `--registry URL` or `$C3L_REGISTRY`. `URL` is the base URL as `c3c --fetch-url` takes it, path included (`https://example.org/c3/v1`). Libraries from different registries can live in one project: `sync`, `update` and `outdated` go back to the registry each library came from.

## Why not just `c3c fetch`?

You can. c3l is for when you also want to know *which* version you have, be
sure it is the *same bytes* everywhere, and update on purpose.

## Install

```sh
git clone https://github.com/konimarti/c3l && cd c3l
make PREFIX=~/.local install        # or copy build/c3l into your PATH
```

c3l is written in C3. Building needs `c3c` (0.8.6+) and libcurl; its own
dependencies are vendored in `vendor/`. At run time it calls `c3c` (to read
the project) and `git` (git libraries and publishing).

## Commands

| | |
|---|---|
| `init [name]` | create `c3l.lock` (and a project with `c3c init name`) |
| `add <ns/name[@ver]>` | install from the registry |
| `add <git-url>[@ref]` | install from git. No ref: highest release tag, else HEAD. The lock pins the commit and a hash of the files; `update` moves tags to the newest release tag and follows branches and `HEAD` |
| `add vendor:<name>` | install from c3c's vendor collection (raylib, sdl3, sqlite3, …); `add vendor` lists it |
| `add ./dir` | link a local library into `lib/` with a relative symlink (never publishable) |
| `remove <name>` | remove a library; refuses if another needs it (`--force`) |
| `prune` | remove dependencies nothing needs any more (`--dry-run`) |
| `why <name>` | which libraries require `<name>` |
| `list [--tree]` | libraries and state: `ok`, `modified`, `missing`, `untracked`; `dep` marks pulled-in libraries |
| `verify` | check files against the lock, exit 1 on problems |
| `outdated` | show newer versions |
| `update [name[@ref]...]` | update all, or switch one to a version, tag, branch or commit |
| `sync` | restore from the lock. One failure does not stop the others (exit 1 and a summary) |
| `search <text\|tag:x>`, `info <ns/name>` | registry lookups |
| `migrate` | convert a c3po `project.lock.json` into `c3l.lock` |
| `check`, `pack`, `publish` | publish a library, see [Publishing](#publishing) |

Libraries are stored as `.c3l` zips in the first `dependency-search-paths`
entry (`lib` is added if none is set). Commit them, or ignore them and run
`c3l sync` after cloning.

Options (before or after the command):

| | |
|---|---|
| `--registry URL` | registry base URL for new installs and `search`/`info`/`publish` |
| `--dry-run` | with `update`/`prune`: show what would change |
| `--frozen` | with `sync`: fail if lock and project disagree, never write the lock |
| `--fail-fast` | with `sync`/`update`: stop at the first failure |
| `--strict` | with `add`/`update`: C3 release or platform mismatch, or a dependency cycle, is an error |
| `--force` | with `remove`: remove even if needed |
| `--allow-host HOST` | trust a git or registry host named by a dependency (`file` for local paths) |
| `-h`, `--version` | help, version |

Publishing options are listed under [Publishing](#publishing).

## Mixing with `c3c fetch`

c3l uses the `c3c fetch` registry protocol, so any registry `c3c fetch` can
use works with c3l. A library installed with plain `c3c fetch` shows up as
`untracked` and fails `verify` and `sync --frozen` until you run
`c3l add <ns/name>@<version>` for it.

Not supported: `c3c project fetch` (use `c3l sync`), and registries that
need authentication to download.

## Dependencies

c3c only lists a library's dependencies by name. c3l installs them for you.

```sh
c3l add acme/app      # installs app and what it declares
c3l list --tree       # show the dependency graph
c3l why dcc           # who requires dcc?
c3l remove app && c3l prune
```

A library declares its dependencies in `manifest.json`:

```json
"vendor": { "c3l": { "requires": [
    { "name": "vk", "source": "tonis2/vk", "version": "1.0.1" } ] } }
```

`source` is a registry id or git URL. `version` is a minimum (registry) or a
tag, branch or commit (git; `update` moves a tag like any other version). A registry dependency may add `"registry": "<base URL>"`;
without it the default registry is used. `c3l publish` writes this block for you.

Rules:

- If two libraries want different versions of a third, the highest minimum wins. Different major versions are an error.
- Everything is installed flat into `lib/`.
- Cycles are warnings (`--strict` makes them errors).
- If anything fails, nothing is changed.
- Libraries you `add` yourself are never pruned.
- Git hosts: github.com, codeberg.org and hosts you typed yourself are trusted. For others c3l asks, or use `--allow-host` / `$C3L_ALLOWED_HOSTS`.
- `sync --frozen` restores from `c3l.lock` without resolving anything.

### Coming from c3po

c3po and c3l share the `lib/` layout. c3l follows dependencies declared in
`vendor.c3po.sources`, and `c3l migrate` locks the commits from a
`project.lock.json`, then `c3l sync` rebuilds them as verified archives. c3l
never writes c3po's files.

## Publishing

c3l publishes to registries with an upload API, currently
[www.c3pkg.eu](https://www.c3pkg.eu).

```sh
cd mylib.c3l                       # a library directory (c3c init-lib mylib)
git tag v1.0.0                     # the version comes from the tag
export C3PKG_TOKEN=c3p_...         # or --token-file FILE, or C3L_TOKEN
c3l check                          # all checks, no upload
c3l publish --description "My library" --license MIT --tags "gpu,vulkan"
```

- **Version**, in order: `--version X.Y.Z`, a semver tag on `HEAD`, `manifest.json`, `project.json`. Versions are immutable once published.
- **Package**: built from git-tracked files, deterministically.
- **Checks**: valid `manifest.json`, clean working tree (`--allow-dirty`), library compiles (`--no-build`), version not yet published, a `--description` on first publish.
- **Token**: create it in the registry under Settings, API tokens. Never pass it as a command-line argument.
- **Dependencies**: `c3l add` them inside the library directory. They go into `manifest.json` automatically. Local `./dir` dependencies are refused.

Other options, given after `check`, `pack` or `publish`: `--license`, `--tags`, `--docs-url`, `--git-url`, `--c3-version`, `--output`, `--offline`. Before or after the command: `--registry-type`.

## Tests

`make test` builds c3l, runs the unit tests (`c3c test`), checks `vendor/`
against `c3l.lock` and runs the offline suite `test/run.sh` against the binary.
`LIVE=1 make test` adds a smoke test against www.c3pkg.eu.

MIT. See LICENSE.
