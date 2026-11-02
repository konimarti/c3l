C3L(1)

# NAME

*c3l* - reproducible dependencies for C3 projects, on top of *c3c fetch*.

# SYNOPSIS

*c3l* [*--registry* _URL_] [*--dry-run*] [*--frozen*] [*--strict*] _COMMAND_ [_ARGS_]

# DESCRIPTION

*c3c fetch* installs libraries but records no version, verifies no checksum and
cannot update or remove. *c3l* adds a lockfile, _c3l.lock_, checksum
verification with rollback, and update, outdated, remove and sync. Libraries are
kept as _.c3l_ zip files in the first entry of _dependency-search-paths_. Run
*c3l* in the project root.

# REQUIREMENTS

*bash* 3.2 or newer, *c3c* with *fetch*, and POSIX tools (*awk*, *sed*, *grep*, *cut*,
*tr*, *sort*, *find*, *cp* and so on), with *sha256sum* or *shasum* and *mktemp*. Some
commands need more: *git* (git libraries, *check*, *pack*, *publish*), *unzip*
(*add*, *sync*, *update*, *list*, *verify*), *zip* (*pack*, *publish*), *curl*
(*publish*, *search*) and, optionally, *jq* (*search*). No Python is needed.

# OPTIONS

Options may appear before or after the command.

*--registry* _URL_, *--registry=*_URL_
	Use this registry base URL for the command (as *c3c --fetch-url* takes it, path
	included). Overrides *C3L_REGISTRY*. It picks the registry for *add*, *search*, *info*
	and *publish*; libraries already in _c3l.lock_ are always fetched from the registry
	recorded for them.

*--dry-run*
	Only print what *update* would change. Has no effect on other commands.

*--frozen*
	For *sync*, meant for CI. Fail if _project.json_ and _c3l.lock_ list different
	libraries, restore only what the lockfile says, and never write the lockfile.
	Has no effect on other commands.

*--strict*
	With *add* and *update*: fail instead of warn when the registry says a library
	was published for another C3 release than your *c3c* (compared by
	major.minor), or does not list your platform, and when libraries require each
	other in a cycle or a library requires itself.

*--fail-fast*
	With *sync* and *update*: stop at the first library that fails. The default is to
	go on with the others and report the failures at the end (exit status 1).

*--force*
	With *remove*: remove the library even if another library requires it.

*--tree*
	With *list*: print the dependency graph instead of the table.

*--allow-host* _HOST_
	Trust _HOST_ for git dependencies named by a library's manifest. Local paths
	and *file://* URLs are the host _file_. See *DEPENDENCIES*.

*--version* _X.Y.Z_, *--version=*_X.Y.Z_
	For *check*, *pack* and *publish*: the version to publish. Without an argument
	(or when the next word does not start with a digit), print the version.

*--token-file* _FILE_
	File with the registry API token (first line). See *PUBLISHING*.

*--description* _TEXT_, *--license* _ID_, *--tags* _a,b_, *--docs-url* _URL_, *--git-url* _URL_
	Package metadata for *publish*. The description is required the first time a
	package is published.

*--c3-version* _X.Y.Z_
	C3 version sent to the registry. Default: the version of *c3c*.

*--output* _FILE_
	For *pack*: where to write the package.

*--allow-dirty*
	Let *check*, *pack* and *publish* run on a working tree with uncommitted changes.

*--no-build*
	Skip the compile check in *check*, *pack* and *publish*.

*--offline*
	Do not query the registry in *check* (the registry is always skipped by *pack*).

*--registry-type* _static|c3pkg_
	Override the detected registry type. See *PUBLISHING*.

*-h*, *--help*
	Print the usage text.

*-v*, *--version*
	Print the version.

# COMMANDS

*init* [_name_]
	Create _c3l.lock_. With _name_ and outside a project, run *c3c init* first.

*add* _namespace/name_[@_version_]
	Install a library from the registry with *c3c fetch*, compare the SHA-256 of the
	download with the registry's checksum, write the lock line. A mismatch or any
	failure restores the previous library file and _project.json_.

*add* _./dir_
	Link a local library directory (_./dir_, _../dir_ or an absolute path with a
	_manifest.json_) into _lib/_ with a symlink, so edits show up in the next build.
	Recorded in the lockfile as kind _path_; *sync* re-creates the link, *update* skips
	it, and its own dependencies are followed. A library that depends on a local
	directory cannot be published.

*add* _git-url_[@_ref_]
	Install from a git repository. _ref_ is a tag, a branch, *HEAD*, or a full
	40-character commit hash; it can also be given as a separate argument. Without
	a _ref_ the highest semantic version tag is used, or HEAD if there are none.
	The ref is resolved to a commit, which is what the lockfile pins. *outdated*
	and *update* follow the tip of *HEAD* and of branches; tags and commits stay
	put. In scp-style URLs (_git@host:path_) the *@* only starts a ref after the
	last */*. The library is built with *git archive*, so no _.git_ is included, and without
	line-ending conversion. A git library is identified by its commit: the lockfile
	pins it, and *verify* and *sync* check that the installed file is an archive of
	that commit (*git archive* stores the commit id in the zip comment). Edits made
	inside the installed file are therefore not detected for git libraries, unlike
	for registry libraries, which are checked against their SHA-256. This needs
	*git* and *unzip*. The repository needs a _manifest.json_ at its root.

*remove* _name_
	Delete the library file, its _dependencies_ entry and its lock line. Refuses if
	another library requires it (*--force* overrides) and lists libraries that are no
	longer needed.

*prune*
	Remove dependency libraries that no directly added library needs any more.
	With *--dry-run* only list them.

*why* _name_
	Show which libraries require _name_, and why they are installed.

*list* [*--tree*]
	Show every locked library with its state: _ok_, _modified_, _missing_,
	_unpacked_, and _untracked_ for libraries in _project.json_ not in the lockfile.
	_dep_ marks a library pulled in by another one. With *--tree* print the
	dependency graph.

*verify*
	Check installed files against the lockfile. Exit status 1 on any difference.

*outdated*
	Show locked libraries for which the registry (or git) has a higher version.

*update* [_name_[@_ref_] ...]
	Update to the newest version, one library at a time, with rollback. With
	_name_@_ref_ switch that library to an explicit version instead: a registry
	version, or for git libraries a tag, branch, *HEAD* or full commit hash (for
	example *c3l update lib@HEAD* moves a tag-locked library to HEAD). With
	*--dry-run* only print what would change.

*sync*
	Make the project match _c3l.lock_: reinstall missing or modified libraries at the
	locked version and verify against the locked checksum or commit. With
	*--frozen* fail instead if _project.json_ and the lockfile list different
	libraries, and never write the lockfile. A library that cannot be restored does
	not stop the others: *sync* goes on, then exits with status 1 and names the
	failures. *--fail-fast* stops at the first one. Each library is still restored
	atomically.

*search* _text_ | *tag:*_name_
	Search the registry (the _/search_ endpoint, else *c3c fetch-list*).

*info* _namespace/name_
	Run *c3c fetch-info*.

*migrate*
	Convert a c3po _project.lock.json_ into _c3l.lock_. The same commits are locked
	as git libraries; run *sync* afterwards to rebuild them as verified archives.

*check* [_dir_]
	Verify that the library in _dir_ (default: .) can be published, without
	uploading: _manifest.json_ with _provides_, a valid version, a clean working
	tree, the library compiles, and the version is not yet on the registry.
	Exit status 1 on any problem.

*pack* [_dir_]
	Write _name-version.c3l_ (or *--output*): a zip with _manifest.json_ at its
	root and the repository files (git: tracked and untracked-not-ignored; not
	_.git_). The archive is deterministic, the same tree gives the same bytes.

*publish* [_dir_]
	Run *check*, *pack* and upload to the registry, then compare the registry's
	checksum with the uploaded file. With *--dry-run* stop before the upload.

# PUBLISHING

*publish* needs a registry with an upload API. Registry types: _c3pkg_ (www.c3pkg.eu;
detected by probing _/api/v1/packages_) and _static_ (read-only, anything else).
A new type is one set of functions in the script.

For c3pkg: create an API token under Settings, API tokens, and give it to c3l with
*--token-file* _FILE_, *C3L_TOKEN* or *C3PKG_TOKEN*. It is sent as
_Authorization: Bearer_ from a private temporary file, never on the command line.

The package name is _provides_ in _manifest.json_ of the library directory (see
*c3c init-lib*). The version is, in this order: *--version*, a semantic version tag on
HEAD (_v1.2.3_ or _1.2.3_), _version_ in _manifest.json_, _version_ in
_project.json_ (_manifest.json_ wins). If the manifest or the project file says
something else, c3l warns and the archive gets the chosen version; the files in the
repository are not changed. A version is _MAJOR.MINOR.PATCH_ or
_MAJOR.MINOR.PATCH-prerelease_ and can never be changed once published.

The C3 version of the library is sent with each upload and checked on *add* and
*info*: a different major.minor or a missing platform gives a warning (an error
with *--strict*).

# DEPENDENCIES

A library directory (a _manifest.json_ and no _project.json_) works too: *add* installs
into _./lib_ (keep it out of git; it is never packed), lists only the dependencies you
asked for in the manifest's _dependencies_, and writes _c3l.lock_, from which *publish*
fills in _vendor.c3l.requires_.

c3c lists a library's dependencies by name only and does not install them
transitively: every one must be in _project.json_. *add* and *update* therefore
follow the dependencies a library declares and add them all, flat, to _lib_ and
_project.json_, as one transaction.

A library declares them in its _manifest.json_ (c3c ignores the _vendor_ key):

```
"vendor": { "c3l": { "requires": [
    { "name": "vk", "source": "tonis2/vk", "version": "1.0.1" } ] } }
```

_source_ is a registry id or a git URL. A registry source may add _registry_, the
registry base URL; without it the default registry is used, and a registry that no
installed library comes from yet needs *--allow-host*. _version_ is the minimum for
registry libraries, a tag, branch or commit for git libraries. *publish* writes this block
from the library's own _c3l.lock_. c3l also reads c3po's _vendor.c3po.sources_ and
c3c's plain _dependencies_ names (no source: a warning, and *verify* fails until
the library is added).

Versions are chosen as in Go (minimum version selection): the highest of all
requested minimums, never newer. Different major versions are an error. A cycle,
or a library requiring itself, is a warning (an error with *--strict*); each
library is installed once. Git sources other than github.com, codeberg.org and the
hosts of URLs given on the command line need *--allow-host* or an answer at the
prompt. More than 200 libraries are refused.

# LOCKFILE

Tab separated, one library per line, sorted by name:

```
# c3l.lock v1
box2d	registry	https://www.c3pkg.eu	jecokef902/box2d	1.0.0	sha256:4945...	sha256:4945...	direct	-
hex	git	https://github.com/konimarti/hex.c3l	-	v0.1.1	commit:3fa9...	commit:3fa9...	direct	-
```

Columns: name, kind (_registry_, _git_ or _path_), origin, id, version, pin (checksum
or commit), SHA-256 of the installed file (registry) or the commit again (git), role
(_direct_: added by you; _dep_: required by another library) and the comma
separated names the library requires (_-_ for none).

The origin is where the library is fetched from: the registry base URL (what
*c3c --fetch-url* gets, no trailing slash), the git repository URL, or the directory.
The id is _namespace/name_ for a registry and _-_ otherwise. Every line names its own
origin, so one project can mix registries. Library names stay unique: the same name
from two origins is an error. A file with another number of columns is refused.

# ENVIRONMENT VARIABLES

_C3L_REGISTRY_
	Registry base URL for new installs. Overridden by *--registry*.
	Default: https://www.c3pkg.eu

_C3L_ALLOWED_HOSTS_
	Space separated git hosts that dependencies may fetch from, in addition to
	github.com and codeberg.org.

_C3L_MAX_DEPS_
	Largest number of transitive libraries one command may install. Default: 200.

_C3L_TOKEN_, _C3PKG_TOKEN_
	API token for *publish*, if no *--token-file* is given.

_C3L_REGISTRY_TYPE_
	Same as *--registry-type*.

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
