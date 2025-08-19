#!/bin/sh

tmpdir() {
	local template="c3l.test.XXXXXXXXXXXXX"
	TMPDIR="$(mktemp -d "$template")"
	remove_tmpfile() {
		rm -rf "$TMPDIR"
	}
	trap remove_tmpfile EXIT
}

tmpdir
cwd=$(pwd)
cd $TMPDIR
c3c init app
cd app
cat <<EOF > src/main.c3
import encoding::hex;
fn void main() => (void)hex::dump_bytes("c3 is great");
EOF
echo "\n -- fetch -- "
../../c3l fetch https://github.com/konimarti/hex.c3l
c3c build 2>/dev/null
c3c build
build/app
echo "\n -- show -- "
../../c3l show
echo "\n -- remove -- "
../../c3l rm hex.c3l
cd $cwd

