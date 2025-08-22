# c3l

**c3l** is a **library manager for C3 projects**. It streamlines the process of
fetching, updating, and managing C3 libraries from remote repositories. With
c3l, all metadata about your libraries is tracked in a simple `.c3l.deps` file,
making maintenance and versioning of your project dependencies effortless.

*No more manual cloning: Keep your C3 projects organized and reproducible with c3l!*

## Features

- **Fetch libraries**: Download and integrate remote C3 libraries into your project with a single command.
- **Simple updates**: Easily update libraries to newer versions, using tagged releases.
- **Safe removal**: Uninstall libraries cleanly without manually touching `project.json`.
- **Seamless workflow**: Keeps your project files organized and in sync with your dependencies.

***

## How It Works

- When you use c3l to add a library to your project, it:
    - Fetches the library from the specified remote repository.
    - Updates your project files to include the new dependency.
    - Writes an entry to `.c3l.deps` with version, source, and other meta information.
    - Pulls in all dependencies from `.c3l.deps` (if the libraries are not check in the repo)
- Updates and removals use the data in `.c3l.deps` to ensure reliability.
- Updating a dependency (to a new tagged release) is as easy as running a
  single c3l command.

***

## Getting Started

### 1. Installation

Download and install c3l:
```bash
git clone https://github.com/konimarti/c3l
sudo make install
```

`c3l` will be installed in `/usr/local/bin` by default and the man page in
`/usr/local/man/`.

If you want to install it to a different location, set the `PREFIX`
variable when running `make install`:
```bash
make PREFIX=~/.local/ install
```

### 2. Adding a Library

```bash
c3l fetch https://github.com/username/libname v1.0.0
```

- This fetches the specified C3 library and registers it in `.c3l.deps` and
  `project.json`.


### 3. Updating a Library

```bash
c3l update libname
```

- Updates the library to the newest tagged release, updating the metadata in
  `.c3l.deps`.


### 4. Removing a Library

```bash
c3l remove libname
```

- Uninstalls the library and removes its entry from `.c3l.deps` and
  `project.json`.


### %. Pulling all Libraries

```bash
c3l pull
```

- Fetches all the libraries from  `.c3l.deps`. Usually done when the project is
  cloned and only `.c3l.deps` is version controlled but no the libraries.

***

## The `.c3l.deps` File

Some relevant dependency information—including name, source URL, current version or
tag—is stored in a `.c3l.deps` file at your project root. This enables:

- Easy auditing of all dependencies in use
- Clean removal and easy updating

***

## Example Workflow for a New C3 Project

Note that you need the [C3 compiler](https://github.com/c3-lang/c3c)
`c3c` to run this example.

```bash
# Create a new C3 project
c3c init app && cd app

# Update main.c3
cat <<EOF > src/main.c3
import encoding::hex;
fn void main() => (void)hex::dump_bytes("C3 is great");
EOF

# Add the required library
c3l fetch https://github.com/konimarti/hex.c3l v0.1.1

# Now run the app
c3l run

# Update a library to the newest release
c3l update hex

# List installed libraries
c3l list

# Remove a library
c3l remove hex
```

***

## License

MIT. See `LICENSE` for full text.

***

## Contributing

Contributions welcome! Please open an issue or submit a pull request to get started.

