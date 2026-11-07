# c3l

**Add a C3 library in one command. Ship the exact code you tested.**
c3l pins the version, checks the download and installs what the library needs.

- **Reproducible.** `c3l.lock` pins every version and checksum; `c3l sync` restores it.
- **Any source.** c3pkg, c3lang (c3c's vendor libraries), git or a local directory, in one project.
- **Dependencies handled.** Transitive installs, and conflicts that name both sides.
- **Stay current.** `outdated` and `update` stay within compatible versions.
- **Publish in two commands.** `check`, then `publish`.

```sh
c3l add tonis2/vk        # from a registry, git or a local dir
git add c3l.lock         # commit the lock
c3l sync                 # on any clone: the exact same libraries
```

## Install

Download a binary for Linux, macOS or Windows from the
[releases page](https://github.com/konimarti/c3l/releases), or build it with
c3c 0.8.5+:

```sh
git clone https://github.com/konimarti/c3l && cd c3l
make PREFIX=~/.local install
```

c3l calls `c3c` to read your project, and `git` for git libraries.

## Use

```sh
c3l init app && cd app                 # a new project (c3c init) with a c3l.lock
c3l search sqlite                      # asks c3pkg and c3lang at once, shows where each hit is from
c3l add tonis2/vk                      # from c3pkg (the default registry)
c3l add c3lang/sqlite3                 # from c3lang, c3c's vendor libraries
c3l add github.com/you/lib@v1.2.0      # from git: any URL, with a tag, branch or commit
c3l add ../mylib                       # a local library, linked
git add c3l.lock                       # commit the lock

c3l sync                               # after cloning: restore what c3l.lock says
c3l outdated && c3l update             # move to newer compatible versions
c3l list --tree                        # what is installed, and why
```

| Command | |
|---|---|
| `add`, `remove`, `prune` | install a library with its dependencies, remove one, remove what nothing needs any more |
| `sync [--frozen]` | restore from `c3l.lock`; `--frozen` (CI) fails if project and lock disagree |
| `outdated`, `update [name[@version]]` | show and take newer compatible versions, or move to a given one |
| `list [--tree]`, `why <name>`, `verify` | what is installed, who needs it, whether it matches the lock |
| `search <text>`, `info <ns/name>` | look up libraries |
| `check`, `pack`, `publish` | publish a library |
| `migrate` | import a c3po `project.lock.json` or a c3l 0.x `.c3l.deps` |

`c3l help <command>` and `man c3l` have the details;
`source <(c3l completion bash)` (or `zsh`, `fish`) completes commands.

## Versions

When two libraries need the same library, c3l takes the highest version either
asks for, never a newer one. The versions must be compatible, as in Cargo: the
same major version, and below 1.0 the same minor. If they are not, nothing is
installed and c3l shows both sides:

```
[ERROR] version conflict on dl: 1.0.0 is installed, and 1.x and 2.x are not compatible; update or remove one side:
  db -> dl: db asks for 2.0.0 (being added)
  top -> da -> dl: da asks for 1.0.0
```

## Libraries

A library declares its dependencies the way an app does: run `c3l add` in the
library directory and commit its `c3l.lock`. Whoever installs the library gets
those dependencies too.

## Publishing

```sh
cd mylib                               # made with c3c init-lib mylib
git tag v1.0.0                         # the version to publish
c3l check                              # everything but the upload
export C3PKG_TOKEN=c3p_...             # an API token from www.c3pkg.eu's settings
c3l publish --description "My library" --license MIT
```

- `check` makes sure the library compiles, the working tree is committed and
  the version is new. Published versions cannot change.
- The package is built from the files git tracks, the same bytes every time,
  with `c3l.lock`, so its dependencies come along. Libraries in `lib/` are not
  packed; `check` stops if the library needs one that `c3l.lock` doesn't list.
- `c3l pack` writes the package without uploading it.

## Submodules

A git library can also live as a git submodule in `lib/`, for contributors who
clone with `--recurse-submodules`:

```sh
git submodule add https://github.com/you/lib lib/lib.c3l
c3l migrate                            # lock it in c3l.lock
c3l sync                               # after a plain clone: checks it out
c3l update lib                         # moves the submodule and stages it
```

c3l never overwrites a submodule or discards changes in it, and never commits.
Whoever installs your library gets it from `c3l.lock` as usual.

## Notes

- Private git repositories work with whatever gives git access: an ssh key or a
  credential helper. `man c3l` shows how in CI.
- On Windows, linking a local library needs Developer Mode.
- c3l follows the dependencies in c3po manifests.

MIT, see LICENSE. `make test` runs the tests.
