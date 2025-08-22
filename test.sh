#!/usr/bin/env bash

# Copyright (C) 2025 Koni Marti <koni.marti@gmail.com>. All Rights Reserved.
# This file is licensed under the MIT.

tmpdir() {
	local template="c3l.test.XXXXXXXXXXXXX"
	TMPDIR="$(mktemp -d "$template")"
	remove_tmpfile() {
		rm -rf "$TMPDIR"
	}
	trap remove_tmpfile EXIT
}

CWD=$(pwd)
C3L="../../c3l"

tmpdir # set TMPDIR
cd $TMPDIR

c3c init app && cd app

cat <<EOF > src/main.c3
import encoding::hex;
fn void main() => (void)hex::dump_bytes("c3 is great");
EOF

echo " -- fetch v0.1.1 -- "
$C3L f https://github.com/konimarti/hex.c3l v0.1.1

echo " -- list -- "
$C3L l

echo " -- update to newest version -- "
$C3L u hex.c3l

echo " -- list -- "
$C3L l

echo " -- run app -- "
c3c build 2>/dev/null
c3c build
build/app

echo " -- remove -- "
$C3L r hex.c3l
cd $CWD

