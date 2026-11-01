#!/usr/bin/env bash
# Copyright (C) 2025-2026 Koni Marti <koni.marti@gmail.com>. All Rights Reserved.
# This file is licensed under the MIT.
#
# c3l test suite. Offline: a static fake registry (python http.server) and local
# git repositories. Needs c3c with `fetch` support in PATH (or $C3C), git, python3.
#
#   test/run.sh            run all tests
#   LIVE=1 test/run.sh     additionally smoke-test against www.c3pkg.eu

HERE="$(cd "$(dirname "$0")" && pwd)"
C3L="$HERE/../c3l"
export C3C="${C3C:-c3c}"
command -v "$C3C" >/dev/null || { echo "SKIP: c3c not found"; exit 0; }
"$C3C" --help 2>&1 | grep -q fetch-info || { echo "SKIP: c3c has no fetch support"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 needed"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git needed"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/c3l.test.XXXXXX")"
REG="$WORK/reg"; mkdir -p "$REG"
PORT=$((20000 + RANDOM % 20000))
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$REG" >/dev/null 2>&1 &
SERVER=$!
cleanup() { kill "$SERVER" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
for _ in $(seq 1 50); do curl -fs -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
export C3L_REGISTRY="http://127.0.0.1:$PORT"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }
check() { # description cmd...
	local d="$1"; shift
	if "$@" >/dev/null 2>&1; then ok; else fail "$d"; fi
}
check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else ok; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok; else fail "$1: expected '$3', got '$2'"; fi; }
has() { if grep -q -- "$2" <<< "$3"; then ok; else fail "$1: '$2' not in: $3"; fi; }
section() { echo "== $*"; }
publish() { python3 "$HERE/fakereg.py" "$REG" publish "$@"; }
c3l() { "$C3L" "$@"; }
newproj() { # dir
	rm -rf "$WORK/$1"; mkdir -p "$WORK/$1"; cd "$WORK/$1" || exit 1
	"$C3C" init app >/dev/null && cd app || exit 1
}
sha() { sha256sum "$1" | cut -d' ' -f1; }

#
section "semver"
# shellcheck disable=SC1090
source "$C3L"
for t in "1.0.0 1.0.0 0" "1.0.1 1.0.0 1" "1.0.0 1.0.1 -1" "1.10.0 1.9.0 1" "v2.0 1.9.9 1" \
	"1.0.0 1.0.0-rc.1 1" "1.0.0-rc.1 1.0.0 -1" "1.0.0-rc.2 1.0.0-rc.10 -1" "1.0.0-alpha 1.0.0-alpha.1 -1" \
	"1.0.0-alpha.1 1.0.0-beta -1" "1.0.0-1 1.0.0-alpha -1" "1.0.0+b1 1.0.0+b2 0"; do
	set -- $t; eq "semver_cmp $1 $2" "$(semver_cmp "$1" "$2")" "$3"
done

#
section "init, add, list, verify"
newproj p1
check "init creates lock" c3l init
has "lock header" "@registry" "$(cat c3l.lock)"
publish acme/alpha 1.0.0 >/dev/null
out="$(c3l add acme/alpha 2>&1)"; eq "add rc" $? 0
has "add output" "installed alpha 1.0.0" "$out"
check "file installed" test -f lib/alpha.c3l
has "project registered" '"alpha"' "$(cat project.json)"
SUM="$(sha lib/alpha.c3l)"
has "lock has hash" "sha256:$SUM" "$(cat c3l.lock)"
has "list ok" "alpha .*ok" "$(c3l list)"
check "verify ok" c3l verify

section "bad checksum is rejected and rolled back"
cp project.json "$WORK/project.before"; cp c3l.lock "$WORK/lock.before"
publish evil/beta 1.0.0 --badsum >/dev/null
out="$(c3l add evil/beta 2>&1)"; eq "bad sum rc" $? 1
has "mismatch message" "checksum mismatch" "$out"
check_not "no file left" test -e lib/beta.c3l
check "project unchanged" cmp -s project.json "$WORK/project.before"
check "lock unchanged" cmp -s c3l.lock "$WORK/lock.before"

section "missing checksum -> trust on first use, with warning"
publish acme/nosum 1.0.0 --no-checksum >/dev/null
out="$(c3l add acme/nosum 2>&1)"; eq "nosum rc" $? 0
has "tofu warning" "trust on first use" "$out"
c3l remove nosum >/dev/null 2>&1

section "unknown version / unknown library"
check_not "unknown version fails" c3l add acme/alpha@9.9.9
check_not "unknown lib fails" c3l add nobody/nothing
check_not "bad id fails" c3l add notanid

section "name collision between namespaces"
publish other/alpha 1.0.0 >/dev/null
out="$(c3l add other/alpha 2>&1)"; eq "collision rc" $? 1
has "collision text" "already installed" "$out"
check "alpha untouched" c3l verify

section "outdated / update"
publish acme/alpha 1.1.0 >/dev/null
has "outdated lists alpha" "alpha .*1.0.0 .*-> 1.1.0" "$(c3l outdated)"
out="$(c3l update --dry-run 2>&1)"; has "dry run" "dry run" "$out"
has "lock still 1.0.0" "1.0.0" "$(grep '^alpha' c3l.lock)"
c3l update >/dev/null 2>&1; eq "update rc" $? 0
has "lock now 1.1.0" "1.1.0" "$(grep '^alpha' c3l.lock)"
check "verify after update" c3l verify
has "up to date" "up to date" "$(c3l outdated)"

section "failed update rolls back"
BEFORE="$(sha lib/alpha.c3l)"; cp c3l.lock "$WORK/lock.before"; cp project.json "$WORK/project.before"
publish acme/alpha 1.2.0 --badsum >/dev/null
out="$(c3l update alpha 2>&1)"; eq "bad update rc" $? 1
eq "old file restored" "$(sha lib/alpha.c3l)" "$BEFORE"
check "lock unchanged" cmp -s c3l.lock "$WORK/lock.before"
check "project unchanged" cmp -s project.json "$WORK/project.before"
check "verify still ok" c3l verify

section "prerelease is not newer than release"
publish acme/pre 1.0.0 >/dev/null; c3l add acme/pre >/dev/null 2>&1
publish acme/pre 1.1.0-rc.1 --not-latest >/dev/null
check_not "no update to rc" bash -c "'$C3L' outdated | grep -q '^pre '"

section "verify detects tampering; sync restores"
echo junk >> lib/alpha.c3l
check_not "verify fails" c3l verify
has "list shows modified" "modified" "$(c3l list)"
c3l sync >/dev/null 2>&1; eq "sync rc" $? 0
check "verify ok again" c3l verify

section "sync on a fresh checkout"
rm -rf lib/*.c3l
cp "$HERE/../README.md" /dev/null
sed -i.bak 's/"dependencies":.*/"dependencies": [ ],/' project.json && rm -f project.json.bak
c3l sync >/dev/null 2>&1; eq "fresh sync rc" $? 0
check "alpha back" test -f lib/alpha.c3l
has "deps back" '"alpha"' "$(cat project.json)"
check "verify ok" c3l verify

section "sync --frozen detects drift"
cp project.json "$WORK/project.good"
sed -i.bak 's/"dependencies":  *\[/"dependencies": [ "ghost",/' project.json && rm -f project.json.bak
out="$(c3l sync --frozen 2>&1)"; eq "frozen rc" $? 1
has "drift reported" "ghost" "$out"
cp "$WORK/project.good" project.json
check "frozen ok when consistent" c3l sync --frozen

section "remove is exact, not a prefix match"
publish acme/hex 1.0.0 >/dev/null; publish acme/hexdump 1.0.0 >/dev/null
c3l add acme/hex >/dev/null 2>&1; c3l add acme/hexdump >/dev/null 2>&1
c3l remove hex >/dev/null 2>&1; eq "remove rc" $? 0
check_not "hex gone" test -e lib/hex.c3l
check "hexdump kept" test -f lib/hexdump.c3l
has "hexdump still locked" "^hexdump" "$(cat c3l.lock)"
check_not "hex not locked" grep -q '^hex	' c3l.lock
has "hexdump still in project" '"hexdump"' "$(cat project.json)"
check "verify ok" c3l verify

section "unpacked (c3c default) copy is replaced by a file"
newproj p2
c3l init >/dev/null 2>&1
"$C3C" --fetch-url "$C3L_REGISTRY" fetch acme/alpha@1.0.0 >/dev/null 2>&1
check "c3c unpacked it" test -d lib/alpha.c3l
c3l add acme/alpha@1.0.0 >/dev/null 2>&1; eq "add over dir rc" $? 0
check "now a file" test -f lib/alpha.c3l
check "verify ok" c3l verify
has "untracked shows for foreign dep" "alpha" "$(c3l list)"

section "untracked dependency is reported"
cp project.json "$WORK/p2.json"
sed -i.bak 's/"dependencies":  *\[/"dependencies": [ "stranger",/' project.json && rm -f project.json.bak
has "untracked" "stranger .*untracked" "$(c3l list)"
check_not "verify flags it" c3l verify

section "deps_edit: json5, comments, multi-line, target-level"
newproj p3
cat > project.json5 <<'EOF'
{
  // top comment with "dependencies": [ "decoy" ]
  "langrev": "1",
  "dependency-search-paths": [ "lib" ],
  "dependencies": [
    "one", // first
    "two"
  ],
  "targets": {
    "app": { "type": "executable", "dependencies": [ "targetonly" ] },
  },
}
EOF
rm -f project.json
PROJECT=project.json5
check "add three" deps_edit add three
eq "deps after add" "$(deps_list | tr '\n' ' ')" "one two three "
check "add is idempotent" deps_edit add three
eq "deps still" "$(deps_list | tr '\n' ' ')" "one two three "
check "del two" deps_edit del two
eq "deps after del" "$(deps_list | tr '\n' ' ')" "one three "
has "target-level untouched" '"targetonly"' "$(cat project.json5)"
has "comment untouched" 'decoy' "$(cat project.json5)"
check "del missing is a no-op" deps_edit del nothere
check "del all" bash -c "source '$C3L'; PROJECT=project.json5; deps_edit del one && deps_edit del three"
eq "empty" "$(deps_list | tr '\n' ' ')" ""
newproj p4
cat > project.json <<'EOF'
{ "dependency-search-paths": [ "lib" ], "targets": { "app": { "type": "executable" } } }
EOF
PROJECT=project.json
check "add when key is missing" deps_edit add first
eq "created" "$(deps_list | tr '\n' ' ')" "first "

section "registry under a base path, with trailing slash"
mkdir -p "$REG/c3/v1"; python3 "$HERE/fakereg.py" "$REG/c3/v1" publish acme/zed 1.0.0 >/dev/null
newproj p7
out="$(c3l --registry "$C3L_REGISTRY/c3/v1/" add acme/zed 2>&1)"; eq "base path rc" $? 0
has "registry stored without trailing slash" "@registry	$C3L_REGISTRY/c3/v1$" "$(cat c3l.lock)"
check "later commands use the locked registry" env -u C3L_REGISTRY "$C3L" outdated
check "verify" c3l verify

section "git source"
GR="$WORK/gitlib"; mkdir -p "$GR/src"; cd "$GR" || exit 1
git init -q . && git config commit.gpgsign false
echo '{ "provides": "gitlib", "version": "0.1.0", "targets": {} }' > manifest.json
echo 'module gitlib;' > src/gitlib.c3
echo secret > .hidden-but-tracked
git add -A && git commit -qm one && git tag v0.1.0
C1="$(git rev-parse HEAD)"
echo 'module gitlib; fn int x() => 1;' > src/gitlib.c3
git commit -qam two && git tag -a v0.2.0 -m two
C2="$(git rev-parse HEAD)"
newproj p5
c3l init >/dev/null 2>&1
out="$(c3l add "file://$GR" 2>&1)"; eq "git add rc" $? 0
has "latest tag chosen" "installed gitlib v0.2.0" "$out"
rec="$(grep '^gitlib' c3l.lock)"
has "commit pinned (annotated tag peeled)" "commit:$C2" "$rec"
check "file is a zip" python3 -c "import zipfile;zipfile.ZipFile('lib/gitlib.c3l').getinfo('manifest.json')"
check_not ".git not packed" python3 -c "import zipfile,sys;sys.exit(0 if any(n.startswith('.git/') for n in zipfile.ZipFile('lib/gitlib.c3l').namelist()) else 1)"
check "verify ok" c3l verify
c3l remove gitlib >/dev/null 2>&1
c3l add "file://$GR" v0.1.0 >/dev/null 2>&1; eq "git add tag rc" $? 0
has "older commit pinned" "commit:$C1" "$(grep '^gitlib' c3l.lock)"
has "outdated sees v0.2.0" "v0.1.0 .*-> v0.2.0" "$(c3l outdated)"
rm lib/gitlib.c3l; c3l sync >/dev/null 2>&1; eq "git sync rc" $? 0
check "restored" test -f lib/gitlib.c3l
c3l update >/dev/null 2>&1; eq "git update rc" $? 0
has "updated to v0.2.0" "v0.2.0" "$(grep '^gitlib' c3l.lock)"
check_not "no such tag fails" c3l add "file://$GR" v9.9.9
git -C "$GR" branch -q dev "$C1"
c3l remove gitlib >/dev/null 2>&1
c3l add "file://$GR@HEAD" >/dev/null 2>&1; eq "add @HEAD rc" $? 0
rec="$(grep '^gitlib' c3l.lock)"
has "HEAD locked" "HEAD	.*commit:$C2" "$rec"
git -C "$GR" commit -q --allow-empty -m three; C3="$(git -C "$GR" rev-parse HEAD)"
has "outdated tracks HEAD over tags" "HEAD .*-> HEAD@${C3:0:12}" "$(c3l outdated)"
c3l update >/dev/null 2>&1; has "update follows HEAD" "HEAD	.*commit:$C3" "$(grep '^gitlib' c3l.lock)"
c3l add "file://$GR@dev" >/dev/null 2>&1; eq "add @branch rc" $? 0
has "branch locked" "branch:dev	commit:$C1" "$(grep '^gitlib' c3l.lock)"
rm lib/gitlib.c3l; c3l sync >/dev/null 2>&1; eq "branch sync rc" $? 0
c3l add "file://$GR@$C2" >/dev/null 2>&1; eq "add @commit rc" $? 0
has "commit locked" "commit:${C2:0:12}	commit:$C2" "$(grep '^gitlib' c3l.lock)"
check_not "commit not outdated" bash -c "$(declare -f c3l 2>/dev/null); c3l outdated | grep -q gitlib"
check_not "short hash rejected" c3l add "file://$GR@${C2:0:8}"
check_not "ref both ways rejected" c3l add "file://$GR@v0.1.0" v0.2.0
c3l add "file://$GR@v0.1.0" >/dev/null 2>&1; has "@tag works" "v0.1.0	.*commit:$C1" "$(grep '^gitlib' c3l.lock)"
check_not "not a repo fails" c3l add "file://$WORK/nope"

section "git: repo without manifest is rejected"
NR="$WORK/nomanifest"; mkdir -p "$NR"; (cd "$NR" && git init -q . && echo x > a && git add a && git commit -qm x)
out="$(c3l add "file://$NR" 2>&1)"; eq "no manifest rc" $? 1
has "message" "manifest.json" "$out"

section "migrate from c3l 0.x"
newproj p6
mkdir -p lib; cp "$WORK/p5/app/lib/gitlib.c3l" lib/gitlib.c3l
echo "gitlib.c3l lib/gitlib.c3l file://$GR v0.2.0" > .c3l.deps
c3l migrate >/dev/null 2>&1; eq "migrate rc" $? 0
has "migrated line" "^gitlib.git.file://$GR.v0.2.0.commit:$C2" "$(cat c3l.lock)"
check "old file renamed" test -f .c3l.deps.migrated
check_not "migrate again refuses" c3l migrate

section "cli"
has "help" "reproducible dependencies" "$(c3l help)"
has "version" "c3l 1" "$(c3l version)"
check_not "unknown command" c3l frobnicate
cd "$WORK" && mkdir -p empty && cd empty
check_not "outside project" c3l list

if [[ -n "$LIVE" ]]; then
	section "live: www.c3pkg.eu"
	unset C3L_REGISTRY
	newproj live
	c3l init >/dev/null 2>&1
	check "live add" c3l add jecokef902/box2d
	check "live verify" c3l verify
	has "live search" "tonis2/vk" "$(c3l search vk)"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
