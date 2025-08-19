C3L(1)

# NAME

*c3l* - a library manager for C3 projects.

# SYNOPSIS

*c3l* [*-h*] [*-v*] _COMMAND_ [ _ARGS_ ]

# DESCRIPTION

*c3l* is a *library manager for C3 projects*. It streamlines the process of
fetching, updating, and managing C3 libraries from remote repositories. With
c3l, all metadata about your libraries is tracked in a simple `.c3l.deps` file,
making maintenance and versioning of your project dependencies effortless.

Some relevant dependency information—including name, source URL, current version
or tag—is stored in a `.c3l.deps` file at your project root. This enables easy
auditing of all dependencies in use and als a clean removal and easy updating of
the libraries.

# COMANDS

*fetch* _repo_url_ [ _tag_name_ ]++

	Fetch a C3 library from a git repository at _repo_url_. An optional
	_tag_name_ can used to fetch a specific version. Note that this allows
	the *update* command to work properly.

	*fetch* will update the 'dependency' entry in _project.json_. It will
	also create a new entry in the _.c3l.deps_.

	See also _LOCALREPO_ for using a
	locally stored repository.

*remove* _repo_name_++

	Remove the library _repo_name_ and also update _project.json_ and
	_.c3l.deps_.

*list*
	List all installed libraries that are stored in _.c3l.deps_.

# EXAMPLES

Fetch a C3 library and use it (note the difference between *c3c* and *c3l*):

```
c3c init app
cd app
cat <<EOF > src/main.c3
import encoding::hex;
fn void main() => (void)hex::dump_bytes("C3 is great");
EOF
c3l fetch http://github.com/konimarti/hex.c3l
c3c run
```

Remove a C3 library:

```
c3l rm hex.c3l
```

# ENVIRONMENT VARIABLES

_LOCALREPO_

	Set _LOCALREPO_ to a folder which contains the sources of a C3 library.
	This will prevent *c3l* from using *git clone*.

	Example:
	```
	LOCALREPO=../hex.c3l c3l fetch http://github.com/konimarti/hex.c3l
	```

_DEBUGC3L_

	Set _DEBUGC3L_ to print all executed Bash statements.

	Example:
	```
	DEBUGC3L=1 c3l list
	```

# SEE ALSO

*c3c*(1)

# AUTHOR

c3l was written by Koni Marti.
