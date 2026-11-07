C3L(1)

# NAME

*c3l* - reproducible dependencies for C3 projects, for any *c3c fetch* registry.

# SYNOPSIS

*c3l* [_OPTIONS_] _COMMAND_ [_ARGS_] [_OPTIONS_]

*c3l* *--version* | *--help* | *help* [_COMMAND_]

# DESCRIPTION

*c3c fetch* installs libraries but records no version, verifies no checksum and
cannot update or remove. *c3l* adds a lockfile, _c3l.lock_, checksum
verification with rollback, and update, outdated, remove and sync. Libraries are
kept as _.c3l_ zip files in the first entry of _dependency-search-paths_ (_lib_
is added if there is none); commit them, or ignore them and run *c3l sync* after
cloning. Run *c3l* in the project root.

c3l speaks the registry protocol of *c3c fetch*, so it works with any registry
*c3c fetch* can use. A library installed with plain *c3c fetch* is listed as
_untracked_ and fails *verify* and *sync --frozen* until it is added with *c3l add*.
Not supported: *c3c project fetch* (use *c3l sync*) and registries that need a
login to download.

# REQUIREMENTS

*c3l* is linked against *libcurl*. At run time it calls *c3c* (to read the project
with *c3c project view*, for *init* and for the compile check of *check*) and *git*
(git libraries and submodules, and *check*, *pack*, *publish* in a git repository).
It talks to registries itself, with the protocol *c3c fetch* uses, so any *c3c*
that can build the project will do; registry and vendor libraries need no *git*.

On Windows, *git* is Git for Windows, and linking a local directory (*add* _./dir_)
needs Developer Mode or an administrator, for whom Windows creates symbolic links.
Git for Windows checks files out with CRLF line endings by default
(_core.autocrlf=true_), so a package packed there differs from one packed on
Linux; a library that wants the same bytes everywhere sets _\* text=auto eol=lf_
in its _.gitattributes_. c3l reads a _c3l.lock_ with either line ending.

# OPTIONS

The options from *--registry* to *--registry-type* may appear before or after the
command. The publishing options, from *--version* to *--offline*, follow *check*,
*pack* or *publish*.

*--registry* _URL_, *--registry=*_URL_
	Use this registry base URL for the command (as *c3c --fetch-url* takes it, path
	included). Overrides *C3L_REGISTRY*. It picks the registry for *add*, *search*, *info*
	and *publish*; libraries already in _c3l.lock_ are always fetched from the registry
	recorded for them.

*--dry-run*
	Only print what *update* or *prune* would change, or stop *publish* before the
	upload.

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

*--allow-host* _HOST_
	Trust _HOST_ for git or registry dependencies named by a library's _c3l.lock_ or
	_manifest.json_. Local paths and *file://* URLs are the host _file_. Can be
	repeated. See *DEPENDENCIES*.

*--registry-type* _static|c3pkg_
	Override the detected registry type. See *PUBLISHING*.

*--version* _X.Y.Z_, *--version=*_X.Y.Z_
	After *check*, *pack* or *publish*: the version to publish. Before any command,
	*--version* prints the version of *c3l*.

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

*--tree*
	After *list*: print the dependency graph instead of the table.

*-h*, *--help*
	Print the usage text, of *c3l* or of the command it follows.

# COMMANDS

Some commands have short names: *add* is also *fetch*, *f*, *get* and *g*; *remove* is
*rm*, *r* and *delete*; *update* is *u*; *sync* is *pull* and *p*; *list* is *ls* and *l*;
*search* is *s*.

*init* [_name_]
	Create _c3l.lock_. With _name_ and outside a project, run *c3c init* first.

*add* _namespace/name_[@_version_]
	Install a library from the registry, compare the SHA-256 of the download with
	the registry's checksum, write the lock line. The version can also be given as a
	separate argument. A mismatch or any failure restores the previous library file
	and _project.json_.

*add* vendor:_name_, *add* vendor
	Install a library from c3c's vendor collection (the files of the _c3lang/vendor_
	release _latest_, what *c3c vendor-fetch* downloads). The collection has no
	versions, so the lock pins the SHA-256 that GitHub lists for the file (kind
	_vendor_, version _latest_). *sync* fails if the file changed upstream; *outdated*
	shows such a change and *update* re-pins it. If no digest is listed, c3l warns and
	records the download. Plain *add vendor* lists the collection. A library may
	require one with _"source": "vendor:name"_.

*add* _./dir_
	Link a local library directory (_./dir_, _../dir_ or an absolute path with a
	_manifest.json_) into _lib/_ with a relative symlink, so edits show up in the next
	build and the project and the directory can move together. *verify* checks where
	the link points.
	Recorded in the lockfile as kind _path_; *sync* re-creates the link, *update* skips
	it, and its own dependencies are followed. A library that depends on a local
	directory cannot be published.

*add* _git-url_[@_ref_]
	Install from a git repository. _github.com/owner/repo_ and _codeberg.org/owner/repo_
	without a scheme mean their https URL; for ssh, give the ssh URL
	(_git@github.com:owner/repo_). _ref_ is a tag, a branch, *HEAD*, or a full
	40-character commit hash; it can also be given as a separate argument. Without
	a _ref_ the highest release tag is used (prerelease tags such as _v1.0.0-rc.1_ only
	when asked for), or HEAD if there are none. The ref is resolved to a commit,
	which is what the lockfile pins. *outdated* and *update* move a tag to the
	highest release tag and follow the tip of *HEAD* and of branches; commits stay
	put; a tag only moves to a compatible version (see *DEPENDENCIES*). In scp-style URLs (_git@host:path_) the *@* only starts a ref after the
	last */*. URLs with credentials (_https://user:token@host/..._) are refused: the
	URL is written to the lockfile; see *PRIVATE REPOSITORIES*. The library is built with *git archive*, so no _.git_ is included, and without
	line-ending conversion. A git library is identified by its commit and its files:
	the lockfile pins the commit and records a hash of the files in the archive, and
	*verify* and *sync* check both (*git archive* stores the commit id in the zip
	comment). The hash covers names and contents only, so it does not depend on the
	git version that built the archive. This needs *git*. The repository needs a _manifest.json_ at its root.

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
	_dep_ marks a library pulled in by another one, _submodule_ one stored as a git
	submodule (with its own states, see *GIT SUBMODULES*). With *--tree* print the
	dependency graph.

*verify*
	Check installed files against the lockfile. Exit status 1 on any difference.

*outdated*
	Show locked libraries for which the registry (or git) has a higher version: the
	newest compatible version, which *update* moves to, and a newer version that
	is not compatible, if there is one (see *DEPENDENCIES*). A library whose source cannot be reached is named, and
	the exit status is 1.

*update* [_name_[@_ref_] ...]
	Update to the newest compatible version, one library at a time, with
	rollback; a newer version that is not compatible is only announced. With _name_@_ref_ switch
	that library to an explicit version instead: a registry version, or for git
	libraries a tag, branch, *HEAD* or full commit hash (for example *c3l update
	lib@HEAD* moves a tag-locked library to HEAD). Moving to a version that is not
	compatible fails if a library that requires it asks for the old one. A name that is not in
	the lockfile is an error. With *--dry-run* only print what would change.

*sync*
	Make the project match _c3l.lock_: reinstall missing or modified libraries at the
	locked version and verify against the locked checksum or commit. With
	*--frozen* fail instead if _project.json_ and the lockfile list different
	libraries, and never write the lockfile. A library that cannot be restored does
	not stop the others: *sync* goes on, then exits with status 1 and names the
	failures. *--fail-fast* stops at the first one. Each library is still restored
	atomically.

*search* _text_ | *tag:*_name_
	Search the registry (its _/search_ API, else its _index.json_; the latter is what c3c's static registries have) and c3c's vendor
	collection, by name and description. The vendor list is the one built into this
	c3l, so a library added to the collection since is missing; *add vendor* lists the
	collection as it is now. *tag:* searches the registry only.

*info* _namespace/name_
	Show the registry record of a library: its versions and their checksums, and
	whether the latest one suits this C3 release and platform.

*version*
	Print the version.

*help* [_command_]
	Print the usage text of *c3l* or of _command_.

*completion* _bash_|_zsh_|_fish_
	Print a shell completion script. See *SHELL COMPLETION*.

*migrate*
	Convert a c3po _project.lock.json_, or the _.c3l.deps_ of c3l 0.x, into
	_c3l.lock_. The libraries are locked as git libraries: c3po's commits, or the
	commit each 0.x tag points to now. The old file is not touched; run *sync*
	afterwards to rebuild the libraries as verified archives. Also adopts git
	submodules in the library directory that the lockfile does not list yet, into a
	new or an existing _c3l.lock_ (see *GIT SUBMODULES*).

*check* [_dir_]
	Verify that the library in _dir_ (default: .) can be published, without
	uploading: _manifest.json_ with _provides_, a valid version, a clean working
	tree, the library compiles with only the libraries its _c3l.lock_ brings, and
	the version is not yet on the registry. A library in _lib/_ that the manifest
	depends on but _c3l.lock_ does not list is an error (see *PUBLISHING*).
	Exit status 1 on any problem.

*pack* [_dir_]
	Write _name-version.c3l_ (or *--output*): a zip with _manifest.json_ at its
	root and the repository files (git: tracked and untracked-not-ignored; not
	_.git_, the libraries in _lib/_, _obj/_ or _build/_), _c3l.lock_ included. The archive is
	deterministic, the same tree gives the same bytes.

*publish* [_dir_]
	Run *check*, *pack* and upload to the registry, then compare the registry's
	checksum with the uploaded file. With *--dry-run* stop before the upload.

# PUBLISHING

*publish* needs a registry with an upload API. Registry types: _c3pkg_ (www.c3pkg.eu;
detected by probing _/api/v1/packages_) and _static_ (read-only, anything else).

A _static_ registry speaks c3c's fetch protocol: _info/<ns>/<name>_ lists the versions with
their checksum, and each version is downloaded from its own _url_ when the record has one
(the _c3lang/vendor_ registry points at release assets), else from _download/<ns>/<name>@<version>_.
A version that c3pkg marks yanked still installs for whoever locked it, with a warning.

For c3pkg: create an API token under Settings, API tokens, and give it to c3l with
*--token-file* _FILE_, *C3L_TOKEN* or *C3PKG_TOKEN*. It is sent as
_Authorization: Bearer_ header and never appears on a command line.

The package name is _provides_ in _manifest.json_ of the library directory (see
*c3c init-lib*). The version is, in this order: *--version*, a semantic version tag on
HEAD (_v1.2.3_ or _1.2.3_), _version_ in _manifest.json_, _version_ in
_project.json_ (_manifest.json_ wins). If the manifest or the project file says
something else, c3l warns and the archive gets the chosen version; the files in the
repository are not changed. A version is _MAJOR.MINOR.PATCH_ or
_MAJOR.MINOR.PATCH-prerelease_ and can never be changed once published.

A package carries no other library: c3c finds a library only next to the others in
the project's library directory, never inside one. Dependencies travel in
_c3l.lock_ instead, and installers fetch them; a library in _lib/_ that is not in
_c3l.lock_ stays behind, so *check* refuses one the manifest depends on. Either
publish it (registry or git) and *c3l add* it, or vendor its sources: put them in
the library (e.g. _vendor/name/_) and list them in _"sources"_, so they are
compiled as part of it (rename the module, e.g. _mylib::name_, to avoid a clash
with the real library).

The C3 version of the library is sent with each upload and checked on *add* and
*info*: a different major.minor or a missing platform gives a warning (an error
with *--strict*).

# DEPENDENCIES

A library directory (a _manifest.json_ and no _project.json_) works too: *add* installs
into _./lib_ (keep it out of git; it is never packed), lists only the dependencies you
asked for in the manifest's _dependencies_, and writes _c3l.lock_. Commit the lock: it is
how the library declares its dependencies, and it travels with the library, in its git
archive and in the package *pack* builds.

c3c lists a library's dependencies by name only and does not install them
transitively: every one must be in _project.json_. *add* and *update* therefore
follow the dependencies a library declares and add them all, flat, to _lib_ and
_project.json_, as one transaction.

A library declares them in its _c3l.lock_: each direct entry is a requirement, from
the source it names (a registry the consumer has no library from yet needs
*--allow-host*), at least at the locked version for registry libraries, at the locked
tag, branch or commit for git libraries (*update* moves a tag like any other version).
Apps and libraries alike, _c3l.lock_ is the only file c3l writes dependencies to. So a library that was never
touched by c3l but lists its dependencies as paths still installs them all, and they
end up in _c3l.lock_ as dependencies; c3l never writes a path into a manifest. c3pkg
refuses paths in _dependencies_, and *check* says so before you upload.

c3l also reads, but never writes, _vendor.c3l.requires_ in a library's _manifest.json_
(packages published by c3l 1.1), c3po's _vendor.c3po.sources_ (_c3po-version_ 1; at
the commit the library's _project.lock.json_ pins, if it has one) and
c3c's _dependencies_: a plain name (no source: a warning, and *verify* fails until the
library is added) or a library path, _[url:]ns/name[@version][:sha256]_, which names
the source (_ns/name_ in the registry at _url_, else the default), the minimum version
and the checksum that version's archive must have (64 hex digits, needs a version; a
mismatch with the file or the registry is an error). c3c accepts a path wherever it takes a
name and reduces it to the name itself. For each name the first wins, in this order: _vendor.c3l.requires_,
_c3l.lock_, _vendor.c3po.sources_, _dependencies_. Dependencies that _project.json_ lists for a
single target are part of the project too (*list*, *verify*, *sync --frozen*).

Versions are chosen as in Go (minimum version selection): the highest of all
requested minimums, never newer. Versions that are not compatible are an
error, with the libraries on both sides named. Compatible means, as in Cargo,
the same major version, and below 1.0 the same minor (0.3.1 and 0.3.5, not 0.3
and 0.4: a 0.y release may break the one before); 0.0.z only matches itself. A cycle,
or a library requiring itself, is a warning (an error with *--strict*); each
library is installed once. Git sources other than github.com, codeberg.org and the
hosts of URLs given on the command line need *--allow-host* or an answer at the
prompt. More than 200 libraries are refused.

# PRIVATE REPOSITORIES

c3l runs *git* for git libraries, so private repositories work with whatever gives
git access: an ssh key (_git@github.com:me/lib_) or, for https URLs, a credential
helper (for GitHub: *gh auth setup-git*). git is never allowed to ask on the
terminal; when it fails, c3l shows what git said.

The same repository as _https://host/path_, _ssh://git@host/path_ and
_git@host:path_ counts as one source. Libraries should name their dependencies with
https URLs, which work for everyone; to fetch them over ssh yourself, let git
rewrite them:

```
git config --global url."git@github.com:".insteadOf https://github.com/
```

In CI, give git access to the other repositories: an ssh deploy key with the
rewrite above, or a token (in GitHub Actions a personal access token; the
built-in _GITHUB_TOKEN_ reads only the repository being built):

```
git config --global url."https://x-access-token:${TOKEN}@github.com/".insteadOf https://github.com/
```

# GIT SUBMODULES

A git library can also be kept as a git submodule at _lib/name.c3l_, for
example so that contributors without c3l get it with
*git clone --recurse-submodules*. _c3l.lock_ describes it like any git library
(URL, version, commit, content hash), and anyone who installs your library gets
it from that lockfile, as an archive. Projects whose _.gitmodules_ names no
_.c3l_ path are not affected.

*migrate* adopts submodules the lockfile does not list: the URL from
_.gitmodules_ (it must be absolute), the commit the repository records, a tag
at that commit as the version (else the branch _.gitmodules_ follows, else the
commit), and what they require is installed. *sync* checks a submodule out, or
back to the recorded commit. *update* fetches the new commit into the
submodule, checks it out and stages it; c3l never commits. *verify*, *list*
and *check* report a submodule that is _not-checked-out_, _edited_ (local
changes), _moved_ (another commit checked out), _lock-differs_ (the repository
records another commit than _c3l.lock_; the message shows the *update* that
settles it either way) or _other-source_.

c3l never discards local changes or commits on no branch in a submodule, and
never replaces one with an archive or a link: *add* and *prune* leave it alone,
and *remove* asks for *git rm* first. The same holds for any git repository in
the library directory that holds work. Creating submodules, or converting
between a submodule and an archive, is left to git.

# LOCKFILE

Tab separated, one library per line, sorted by name:

```
# c3l.lock v1
box2d	registry	https://www.c3pkg.eu	jecokef902/box2d	1.0.0	sha256:4945...	sha256:4945...	direct	-
hex	git	https://github.com/konimarti/hex.c3l	-	v0.1.1	commit:3fa9...	commit:3fa9...	direct	-
```

Columns: name, kind (_registry_, _git_, _vendor_ or _path_), origin, id, version, pin (checksum
or commit), what the installed file is checked against (the SHA-256 again for registry and
vendor libraries; for git _content:_ and a SHA-256 over the names and contents of the
files in the archive, or the commit again in locks written by c3l 1.1), role
(_direct_: added by you; _dep_: required by another library) and the comma
separated names the library requires (_-_ for none).

The origin is where the library is fetched from: the registry base URL (what
*c3c --fetch-url* gets, no trailing slash), the git repository URL, or the directory.
The id is _namespace/name_ for a registry and _-_ otherwise. Every line names its own
origin, so one project can mix registries. Library names stay unique: the same name
from two origins is an error (git URLs that differ only in a trailing _/_ or _.git_, or
in case on github.com and codeberg.org, are the same origin). A file with another number
of columns is refused, and so is a line with an invalid name, checksum or commit: a
lockfile can come from someone else's repository.

# SHELL COMPLETION

*c3l completion* prints a script that completes commands and options.

bash: add to _~/.bashrc_, or save the script in _/etc/bash_completion.d/c3l_:

```
source <(c3l completion bash)
```

zsh: add to _~/.zshrc_, after *compinit*:

```
source <(c3l completion zsh)
```

fish:

```
c3l completion fish > ~/.config/fish/completions/c3l.fish
```

# EXIT STATUS

0 on success, 1 when a command fails, 2 for a usage error (an unknown command or
option, a wrong number of arguments), 130 when interrupted (SIGINT or SIGTERM;
what the command changed so far is undone, a second signal stops at once).

# ENVIRONMENT VARIABLES

_C3L_REGISTRY_
	Registry base URL for new installs. Overridden by *--registry*.
	Default: https://www.c3pkg.eu

_C3L_ALLOWED_HOSTS_
	Comma or space separated git hosts that dependencies may fetch from, in addition to
	github.com and codeberg.org.

_C3L_MAX_DEPS_
	Largest number of transitive libraries one command may install. Default: 200.

_C3L_TOKEN_, _C3PKG_TOKEN_
	API token for *publish*, if no *--token-file* is given.

_C3L_REGISTRY_TYPE_
	Same as *--registry-type*.

_C3C_
	The c3c executable.

_C3L_LOCK_
	Lockfile name. Default: _c3l.lock_.

_C3L_VENDOR_URL_, _C3L_VENDOR_API_
	Where the vendor collection and its asset list are read from. Default: the
	_latest_ release of _github.com/c3lang/vendor_.

# SEE ALSO

*c3c*(1)

# AUTHOR

c3l was written by Koni Marti.
