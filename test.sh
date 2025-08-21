#!/bin/bash

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

echo " -- fetch v0.1.1 -- "
../../c3l f https://github.com/konimarti/hex.c3l v0.1.1

echo " -- list -- "
../../c3l l

echo " -- update to newest version -- "
../../c3l u hex.c3l

echo " -- list -- "
../../c3l l

echo " -- run app -- "
c3c build 2>/dev/null
c3c build
build/app

echo " -- remove -- "
../../c3l r hex.c3l
cd $cwd

