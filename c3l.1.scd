C3L(1)

# NAME

*c3l* - reproducible dependencies for C3 projects, on top of *c3c fetch*.

# SYNOPSIS

*c3l* [*--registry* _URL_] [*--dry-run*] [*--frozen*] _COMMAND_ [_ARGS_]

# DESCRIPTION

*c3c fetch* installs libraries but records no version, verifies no checksum and
cannot update or remove. *c3l* adds a lockfile, _c3l.lock_, checksum
verification with rollback, and update, outdated, remove and sync. Libraries are
kept as _.c3l_ zip files in the first entry of _dependency-search-paths_. Run
*c3l* in the project root.

# COMMANDS

*init* [_name_]
	Create _c3l.lock_. With _name_ and outside a project, run *c3c init* first.

*add* _namespace/name_[@_version_]
	Install a library from the registry with *c3c fetch*, compare the SHA-256 of the
	download with the registry's checksum, write the lock line. A mismatch or any
	failure restores the previous library file and _project.json_.

*add* _git-url_[@_ref_]
	Install from a git repository. _ref_ is a tag, a branch, *HEAD*, or a full
	40-character commit hash; it can also be given as a separate argument. Without
	a _ref_ the highest semantic version tag is used, or HEAD if there are none.
	The ref is resolved to a commit, which is what the lockfile pins. *outdated*
	and *update* follow the tip of *HEAD* and of branches; tags and commits stay
	put. In scp-style URLs (_git@host:path_) the *@* only starts a ref after the
	last */*. The library is built with *git archive*, so no _.git_ is included.
	The repository needs a _manifest.json_ at its root.

*remove* _name_
	Delete the library file, its _dependencies_ entry and its lock line.

*list*
	Show every locked library with its state: _ok_, _modified_, _missing_,
	_unpacked_, and _untracked_ for libraries in _project.json_ not in the lockfile.

*verify*
	Check installed files against the lockfile. Exit status 1 on any difference.

*outdated*
	Show locked libraries for which the registry (or git) has a higher version.

*update* [_name_ ...]
	Update to the newest version, one library at a time, with rollback. With
	*--dry-run* only print what would change.

*sync*
	Make the project match _c3l.lock_: reinstall missing or modified libraries at the
	locked version and verify against the locked checksum or commit. With
	*--frozen* fail instead if _project.json_ and the lockfile list different
	libraries, and never write the lockfile.

*search* _text_ | *tag:*_name_
	Search the registry (the _/search_ endpoint, else *c3c fetch-list*).

*info* _namespace/name_
	Run *c3c fetch-info*.

*migrate*
	Convert a c3l 0.x _.c3l.deps_ file into _c3l.lock_.

# LOCKFILE

Tab separated, one library per line, sorted by name:

```
# c3l.lock v1
@registry	https://www.c3pkg.eu
box2d	registry	jecokef902/box2d	1.0.0	sha256:4945...	sha256:4945...
hex	git	https://github.com/konimarti/hex.c3l	v0.1.1	commit:3fa9...	sha256:77ce...
```

Columns: name, kind (_registry_ or _git_), source, version, pin (checksum or
commit), SHA-256 of the installed file.

# ENVIRONMENT VARIABLES

_C3L_REGISTRY_
	Registry base URL. Overridden by *--registry*, overrides the lockfile.
	Default: https://www.c3pkg.eu

_C3C_
	The c3c executable. It needs *fetch* support (0.8.6 or a nightly).

_C3L_LOCK_
	Lockfile name. Default: _c3l.lock_.

_DEBUGC3L_
	Trace all shell statements.

# SEE ALSO

*c3c*(1)

# AUTHOR

c3l was written by Koni Marti.
