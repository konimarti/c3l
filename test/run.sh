#!/usr/bin/env bash
# Copyright (C) 2025-2026 Koni Marti <koni.marti@gmail.com>. All Rights Reserved.
# This file is licensed under the MIT.
#
# c3l test suite: drives the c3l binary. Offline: a static fake registry (python
# http.server), a fake c3pkg API and local git repositories. Needs c3c in PATH (or
# $C3C), git, python3. The pure logic has unit tests in test/unit (c3c test).
#
#   make test                       build, unit tests, then this suite
#   C3L=path/to/c3l test/run.sh     run this suite against another binary
#   LIVE=1 test/run.sh              additionally smoke-test against www.c3pkg.eu

HERE="$(cd "$(dirname "$0")" && pwd)"
C3L="${C3L:-$HERE/../build/c3l}"
[[ -x "$C3L" ]] || { echo "build c3l first (make)"; exit 1; }
export C3C="${C3C:-c3c}"
command -v "$C3C" >/dev/null || { echo "SKIP: c3c not found"; exit 0; }
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
flat() { # JSON5-ish manifest on stdin -> "path<TAB>value" per scalar
	python3 -c '
import json, re, sys
def walk(v, p):
    if isinstance(v, dict):
        for k, x in v.items(): walk(x, f"{p}.{k}" if p else k)
    elif isinstance(v, list):
        for i, x in enumerate(v): walk(x, f"{p}[{i}]")
    else:
        print(f"{p}\t{v}")
walk(json.loads(re.sub(r",(\s*[}\]])", r"\1", re.sub(r"(?m)^\s*//.*$", "", sys.stdin.read()))), "")'
}

#
section "init, add, list, verify"
newproj p1
check "init creates lock" c3l init
eq "fresh lock has no entries" "$(awk -F'\t' '$0 !~ /^#/' c3l.lock | wc -l)" "0"
publish acme/alpha 1.0.0 >/dev/null
out="$(c3l add acme/alpha 2>&1)"; eq "add rc" $? 0
has "add output" "installed alpha 1.0.0" "$out"
check "file installed" test -f lib/alpha.c3l
has "project registered" '"alpha"' "$(cat project.json)"
SUM="$(sha lib/alpha.c3l)"
has "lock has hash" "sha256:$SUM" "$(cat c3l.lock)"
has "lock records origin and id" "^alpha	registry	$C3L_REGISTRY	acme/alpha	1.0.0" "$(cat c3l.lock)"
eq "lock has no @registry header" "$(grep -c '^@' c3l.lock)" "0"
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
if "$C3C" --help 2>&1 | grep -q '^  fetch '; then
	newproj p2
	c3l init >/dev/null 2>&1
	"$C3C" --fetch-url "$C3L_REGISTRY" fetch acme/alpha@1.0.0 >/dev/null 2>&1
	check "c3c unpacked it" test -d lib/alpha.c3l
	c3l add acme/alpha@1.0.0 >/dev/null 2>&1; eq "add over dir rc" $? 0
	check "now a file" test -f lib/alpha.c3l
	check "verify ok" c3l verify
	has "untracked shows for foreign dep" "alpha" "$(c3l list)"
else
	echo "  skipped: this c3c has no 'fetch' (new in 0.8.6)"
fi

section "untracked dependency is reported"
cp project.json "$WORK/p2.json"
sed -i.bak 's/"dependencies":  *\[/"dependencies": [ "stranger",/' project.json && rm -f project.json.bak
has "untracked" "stranger .*untracked" "$(c3l list)"
check_not "verify flags it" c3l verify

section "registry under a base path, with trailing slash"
mkdir -p "$REG/c3/v1"; python3 "$HERE/fakereg.py" "$REG/c3/v1" publish acme/zed 1.0.0 >/dev/null
newproj p7
out="$(c3l --registry "$C3L_REGISTRY/c3/v1/" add acme/zed 2>&1)"; eq "base path rc" $? 0
has "origin stored without trailing slash" "^zed	registry	$C3L_REGISTRY/c3/v1	acme/zed	" "$(cat c3l.lock)"
check "later commands use the registry of the library" env -u C3L_REGISTRY "$C3L" outdated
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
has "outdated sees v0.2.0, not compatible below 1.0" "v0.1.0 .*(not compatible: v0.2.0)" "$(c3l outdated)"
rm lib/gitlib.c3l; c3l sync >/dev/null 2>&1; eq "git sync rc" $? 0
check "restored" test -f lib/gitlib.c3l
c3l update >/dev/null 2>&1; eq "git update rc" $? 0
has "update keeps the compatible v0.1.0" "v0.1.0" "$(grep '^gitlib' c3l.lock)"
c3l update gitlib@v0.2.0 >/dev/null 2>&1; eq "git update to a tag rc" $? 0
has "updated to v0.2.0" "v0.2.0" "$(grep '^gitlib' c3l.lock)"
check_not "no such tag fails" c3l add "file://$GR" v9.9.9
# a git library is identified by its commit and its files: the lock pins the commit,
# verify checks the commit id that `git archive` stores in the zip and the contents
check "lock records the commit and the contents" grep -qE '^gitlib.*	commit:[0-9a-f]{40}	content:[0-9a-f]{64}	' c3l.lock
check "verify ok" c3l verify
git -C "$GR" archive --format=zip -o "$PWD/lib/gitlib.c3l" "$C1"
out="$(c3l verify 2>&1)"; eq "verify rejects an archive of another commit" $? 1
has "reports it as modified" "gitlib: modified" "$out"
c3l sync >/dev/null 2>&1; check "sync restores the locked commit" c3l verify
rm lib/gitlib.c3l; TZ=Asia/Tokyo GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=true c3l sync --frozen >/dev/null 2>&1
eq "frozen sync independent of tz and autocrlf" $? 0
check "verify after that" c3l verify
# a lock written by c3l 1.0 (sha256 of the zip) keeps working
sed -i '/^gitlib/s/\(commit:[0-9a-f]*\)\t[^\t]*$/\1\tsha256:0000/' c3l.lock
check "legacy hash column is ignored for git" c3l verify

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
c3l update gitlib@HEAD >/dev/null 2>&1; eq "update @HEAD rc" $? 0
has "update switched to HEAD" "HEAD	.*commit:$C3" "$(grep '^gitlib' c3l.lock)"
has "dry run prints switch" "HEAD -> v0.1.0 (dry run)" "$(c3l update --dry-run gitlib@v0.1.0 2>&1)"
c3l update gitlib@v0.1.0 >/dev/null 2>&1; eq "update @tag rc" $? 0
has "update switched to tag" "v0.1.0	.*commit:$C1" "$(grep '^gitlib' c3l.lock)"
check_not "update @bogus fails" c3l update gitlib@nope
c3l add "file://$GR@v0.1.0" >/dev/null 2>&1; has "@tag works" "v0.1.0	.*commit:$C1" "$(grep '^gitlib' c3l.lock)"
check_not "not a repo fails" c3l add "file://$WORK/nope"

section "git: repo without manifest is rejected"
NR="$WORK/nomanifest"; mkdir -p "$NR"; (cd "$NR" && git init -q . && echo x > a && git add a && git commit -qm x)
out="$(c3l add "file://$NR" 2>&1)"; eq "no manifest rc" $? 1
has "message" "manifest.json" "$out"

section "dependencies: transitive install, roles, graph"
newproj pd1
c3l init >/dev/null 2>&1
publish acme/dcc 1.0.0 >/dev/null
publish acme/dcb 1.0.0 --requires=acme/dcc:1.0.0 >/dev/null
publish acme/dca 1.0.0 --requires=acme/dcb:1.0.0 >/dev/null
out="$(c3l add acme/dca 2>&1)"; eq "add with deps rc" $? 0
has "dependency installed" "dcb installed for dca" "$out"
has "transitive installed" "dcc installed for dcb" "$out"
for n in dca dcb dcc; do check "$n file" test -f lib/$n.c3l; has "$n in project.json" "\"$n\"" "$(cat project.json)"; done
eq "lock header stays v1" "$(head -n 1 c3l.lock | cut -d' ' -f1-3)" "# c3l.lock v1"
eq "dca is direct" "$(awk -F'\t' '$1=="dca"{print $8}' c3l.lock)" "direct"
eq "dcb is dep" "$(awk -F'\t' '$1=="dcb"{print $8}' c3l.lock)" "dep"
eq "dcb requires dcc" "$(awk -F'\t' '$1=="dcb"{print $9}' c3l.lock)" "dcc"
eq "lock has 9 columns" "$(awk -F'\t' '$1=="dca"{print NF}' c3l.lock)" "9"
check "verify ok" c3l verify
has "list shows dep" "dcb .*ok,dep" "$(c3l list)"
tree="$(c3l list --tree)"; has "tree root" "^dca 1.0.0" "$tree"; has "tree nested" "    dcc 1.0.0" "$tree"
why="$(c3l why dcc 2>&1)"; has "why dcc" "dcb requires dcc" "$why"; has "why chain" "dca requires dcb" "$why"
out="$(c3l remove dcb 2>&1)"; eq "remove needed dep refused" $? 1
has "refusal names dependent" "required by: dca" "$out"
check "dcb still there" test -f lib/dcb.c3l
c3l update dcb >/dev/null 2>&1
eq "update keeps role dep" "$(awk -F'\t' '$1=="dcb"{print $8}' c3l.lock)" "dep"
rm -f lib/dcb.c3l lib/dcc.c3l
c3l sync --frozen >/dev/null 2>&1; eq "frozen sync restores the graph" $? 0
check "dcc restored" test -f lib/dcc.c3l
c3l remove dca >/dev/null 2>&1
out="$(c3l prune --dry-run 2>&1)"; has "prune dry run lists dcb" "dcb: not needed" "$out"
check "dry run kept dcb" test -f lib/dcb.c3l
c3l prune >/dev/null 2>&1; eq "prune rc" $? 0
check_not "dcb pruned" test -e lib/dcb.c3l
check_not "dcc pruned" test -e lib/dcc.c3l
check_not "project.json cleaned" grep -q '"dcb"' project.json
eq "lock empty after prune" "$(awk -F'\t' '$0 !~ /^#/ && $1 !~ /^@/' c3l.lock | wc -l)" "0"

section "dependencies: diamond, minimum version selection, conflicts"
newproj pd2
c3l init >/dev/null 2>&1
publish acme/dl 1.0.0 >/dev/null
publish acme/dl 1.2.0 --not-latest >/dev/null
publish acme/dl 2.0.0 --not-latest >/dev/null
publish acme/dm 1.0.0 --requires=acme/dl:1.2.0 >/dev/null
publish acme/dtop 1.0.0 --requires=acme/dl:1.0.0,acme/dm >/dev/null
out="$(c3l add acme/dtop 2>&1)"; eq "diamond rc" $? 0
has "dl raised to the highest minimum" "dl 1.0.0 -> 1.2.0" "$out"
eq "dl is at 1.2.0" "$(awk -F'\t' '$1=="dl"{print $5}' c3l.lock)" "1.2.0"
check "diamond verify" c3l verify
newproj pd3
c3l init >/dev/null 2>&1; c3l add acme/dl@1.0.0 >/dev/null 2>&1
publish acme/dx 1.0.0 --requires=acme/dl:2.0.0 >/dev/null
cp c3l.lock "$WORK/lock.before"; cp project.json "$WORK/project.before"
out="$(c3l add acme/dx 2>&1)"; eq "major conflict rc" $? 1
has "conflict message" "version conflict on dl: 1.0.0 is installed" "$out"
has "the side being added" "dx -> dl: dx asks for 2.0.0 (being added)" "$out"
has "the installed side" "dl: added by you" "$out"
check "conflict: lock unchanged" cmp -s c3l.lock "$WORK/lock.before"
check "conflict: project unchanged" cmp -s project.json "$WORK/project.before"
check_not "conflict: dx not left behind" test -e lib/dx.c3l

section "dependencies: failure anywhere rolls the whole operation back"
newproj pd4
c3l init >/dev/null 2>&1
publish acme/rok 1.0.0 >/dev/null
publish acme/rtop 1.0.0 --requires=acme/rok:1.0.0,acme/doesnotexist:1.0.0 >/dev/null
cp c3l.lock "$WORK/lock.before"; cp project.json "$WORK/project.before"
out="$(c3l add acme/rtop 2>&1)"; eq "missing dependency rc" $? 1
check "lock unchanged" cmp -s c3l.lock "$WORK/lock.before"
check "project unchanged" cmp -s project.json "$WORK/project.before"
check_not "rok removed again" test -e lib/rok.c3l
check_not "rtop removed again" test -e lib/rtop.c3l

section "dependencies: cycles and self-dependency are warnings, never a loop"
newproj pd5
c3l init >/dev/null 2>&1
publish acme/cp 1.0.0 --requires=acme/cq:1.0.0 >/dev/null
publish acme/cq 1.0.0 --requires=acme/cp:1.0.0 >/dev/null
out="$(timeout 120 "$C3L" add acme/cp 2>&1)"; eq "cycle rc" $? 0
has "cycle warning with path" "dependency cycle: cp -> cq -> cp" "$out"
eq "each installed once" "$(awk -F'\t' '$0 !~ /^#/ && $1 !~ /^@/' c3l.lock | wc -l)" "2"
check "cycle verify" c3l verify
has "tree marks the cycle" "(cycle)" "$(c3l list --tree)"
newproj pd6
c3l init >/dev/null 2>&1
out="$(timeout 120 "$C3L" --strict add acme/cp 2>&1)"; eq "cycle --strict rc" $? 1
has "strict says cycle" "dependency cycle" "$out"
check_not "strict leaves nothing behind" test -e lib/cp.c3l
check_not "strict leaves no cq" test -e lib/cq.c3l
publish acme/selfdep 1.0.0 --requires=acme/selfdep:1.0.0 >/dev/null
out="$(timeout 120 "$C3L" add acme/selfdep 2>&1)"; eq "self dependency rc" $? 0
has "self dependency warning" "lists itself" "$out"

section "dependencies: names without a source (c3c 'dependencies')"
newproj pd7
c3l init >/dev/null 2>&1
publish acme/needs 1.0.0 --deps=nosrc >/dev/null
out="$(c3l add acme/needs 2>&1)"; eq "no-source rc" $? 0
has "warns about the missing source" "needs 'nosrc' but declares no source" "$out"
out="$(c3l verify 2>&1)"; eq "verify fails while it is missing" $? 1
has "verify names it" "requires nosrc, which is not installed" "$out"
publish acme/nosrc 1.0.0 >/dev/null; c3l add acme/nosrc >/dev/null 2>&1
check "verify ok once installed" c3l verify

section "dependencies: c3po manifests are followed (vendor.c3po.sources), hosts are trusted explicitly"
newproj pd8
c3l init >/dev/null 2>&1
publish acme/viapo 1.0.0 --c3po="gitlib|file://$GR" >/dev/null
out="$(c3l add acme/viapo 2>&1)"; eq "untrusted host rc" $? 1
has "refusal explains --allow-host" "allow-host file" "$out"
check_not "nothing left behind" test -e lib/viapo.c3l
out="$(c3l --allow-host file add acme/viapo 2>&1)"; eq "trusted host rc" $? 0
has "c3po source followed" "gitlib installed for viapo" "$out"
eq "gitlib is a dep, git kind" "$(awk -F'\t' '$1=="gitlib"{print $2 "/" $8}' c3l.lock)" "git/dep"
check "c3po verify" c3l verify


section "review fixes: trust list"
newproj pr1
c3l init >/dev/null 2>&1
out="$(C3L_ALLOWED_HOSTS="example.org,file" c3l add acme/viapo 2>&1)"; eq "comma separated C3L_ALLOWED_HOSTS rc" $? 0
has "trusted via env" "gitlib installed for viapo" "$out"
newproj pr2
c3l init >/dev/null 2>&1
out="$(C3L_ALLOWED_HOSTS="" c3l add acme/viapo 2>&1)"; eq "empty list still refuses" $? 1
check "prune is transactional and quiet when nothing to do" c3l prune
section "dependencies: c3po project.lock.json is imported; old 6-column lock lines still work"
newproj pd9
c3l init >/dev/null 2>&1
SHA40="0123456789abcdef0123456789abcdef01234567"
cat > project.lock.json <<JSON
{ "version": 1, "packages": [
  { "name": "seali", "repo": "Ecoral360/seali.c3l", "origin": "github", "path": "lib/seali.c3l", "zip": true, "ref": "", "commit": "$SHA40" },
  { "name": "other", "repo": "o/other", "origin": "codeberg", "path": "lib/other.c3l", "zip": false, "ref": "v1.0.0", "commit": "$SHA40" } ] }
JSON
rm -f c3l.lock
out="$(c3l migrate 2>&1)"; eq "c3po migrate rc" $? 0
has "seali locked at HEAD" "^seali	git	https://github.com/Ecoral360/seali.c3l	-	HEAD	commit:$SHA40" "$(cat c3l.lock)"
has "codeberg mapped, tag kept" "^other	git	https://codeberg.org/o/other	-	v1.0.0	commit:$SHA40" "$(cat c3l.lock)"
newproj pd10
printf '# c3l.lock v1\nold\tregistry\tacme/old\t1.0.0\tsha256:aa\tsha256:aa\tdirect\t-\n' > c3l.lock
out="$(c3l list 2>&1)"; eq "an old 8-column lock is refused rc" $? 1
has "old lock explained" "does not have 9 columns" "$out"

section "publish: check, pack, publish (fake c3pkg server)"
PKG=$((PORT + 1)); PKG429=$((PORT + 2))
python3 "$HERE/fakepkg.py" "$PKG" >/dev/null 2>&1 & PKGPID=$!
python3 "$HERE/fakepkg.py" "$PKG429" --ratelimit >/dev/null 2>&1 & PKGPID2=$!
trap 'kill $PKGPID $PKGPID2 2>/dev/null; cleanup' EXIT
for _ in $(seq 1 50); do curl -fs -o /dev/null "http://127.0.0.1:$PKG/api/v1/packages" && break; sleep 0.1; done
PR="http://127.0.0.1:$PKG"
echo "c3p_test" > "$WORK/token"; echo "c3p_wrong" > "$WORK/badtoken"
rm -rf "$WORK/pub"; mkdir -p "$WORK/pub"; cd "$WORK/pub" && "$C3C" init-lib demo >/dev/null 2>&1 && cd demo.c3l || exit 1
mkdir -p src; printf 'module demo;\nfn int answer() => 42;\n' > src/demo.c3
git init -q .; git add -A; git commit -qm init
pc() { c3l --registry "$PR" "$@"; }

out="$(pc check --offline 2>&1)"; eq "untagged without version rc" $? 1
has "asks for a version" "no version" "$out"
git tag v1.1; out="$(pc check --offline 2>&1)"; eq "non-semver tag ignored" $? 1
git tag v1.0.0
out="$(pc check --offline 2>&1)"; eq "tagged check rc" $? 0
has "version from tag" "from git tag v1.0.0" "$out"
has "compile check ran" "compiles" "$out"
check_not "--version 1.0 rejected" pc check --offline --version 1.0
check_not "build metadata rejected" pc check --offline --version 1.0.0+b1

c3l pack --output "$WORK/a.c3l" >/dev/null 2>&1; eq "pack rc" $? 0
c3l pack --output "$WORK/b.c3l" >/dev/null 2>&1
eq "pack is deterministic" "$(sha "$WORK/a.c3l")" "$(sha "$WORK/b.c3l")"
has "archive manifest has version" '"version" : "1.0.0"' "$(unzip -p "$WORK/a.c3l" manifest.json)"
check_not "git metadata not packed" bash -c "unzip -l '$WORK/a.c3l' | grep -q '\.git/'"

echo dirty >> README.md
out="$(pc check --offline 2>&1)"; eq "dirty tree rc" $? 1
has "dirty message" "not clean" "$out"
check "--allow-dirty passes" pc check --offline --allow-dirty
git checkout -q README.md

# review fixes: unpacked junk is not "dirty"; modes do not depend on umask; nested .c3l is kept
mkdir -p obj tests; echo x > obj/a.o
check "untracked obj/ is not dirt" pc check --offline --no-build
printf '# c3l.lock v1\n' > c3l.lock
out="$(pc check --offline --no-build 2>&1)"; eq "an uncommitted c3l.lock is dirt rc" $? 1
has "the lock is named" "c3l.lock is part of the package, commit it" "$out"
echo x > tests/fixture.c3l; echo y > newfile.c3
check_not "untracked packaged file is dirt" pc check --offline --no-build
rm newfile.c3
( umask 002; c3l pack --no-build --allow-dirty --output "$WORK/u2.c3l" >/dev/null 2>&1 )
( umask 077; c3l pack --no-build --allow-dirty --output "$WORK/u7.c3l" >/dev/null 2>&1 )
eq "pack independent of umask" "$(sha "$WORK/u2.c3l")" "$(sha "$WORK/u7.c3l")"
has "nested .c3l kept" "tests/fixture.c3l" "$(unzip -l "$WORK/u2.c3l")"
check_not "obj/ not packed" bash -c "unzip -l '$WORK/u2.c3l' | grep -q obj/"
rm -rf obj c3l.lock tests
out="$(pc check --offline --version 2>&1)"; eq "--version without value rc" $? 2
has "--version message" "needs a value" "$out"

# publishing a library that has dependencies: its c3l.lock is packed, the manifest is left alone
printf '# c3l.lock v1\ndcb\tregistry\thttp://example.invalid/v1\tacme/dcb\t1.2.0\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tdirect\t-\ndcc\tregistry\thttp://example.invalid/v1\tacme/dcc\t1.0.0\tsha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tsha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tdep\t-\ngl\tgit\thttps://github.com/o/gl\t-\tv0.3.0\tcommit:cccccccccccccccccccccccccccccccccccccccc\tcommit:cccccccccccccccccccccccccccccccccccccccc\tdirect\t-\n' > c3l.lock
c3l pack --no-build --allow-dirty --output "$WORK/withdeps.c3l" >/dev/null 2>&1; eq "pack with a lockfile rc" $? 0
check "c3l.lock is packed" cmp -s c3l.lock <(unzip -p "$WORK/withdeps.c3l" c3l.lock)
check_not "no vendor block is written" bash -c "unzip -p '$WORK/withdeps.c3l' manifest.json | grep -q vendor"
has "repo manifest untouched" '"provides" : "demo"' "$(cat manifest.json)"
rm -f c3l.lock
sed -i 's|"provides" : "demo",|"provides" : "demo",\n  "dependencies" : [ "nowhere", "demo" ],|' manifest.json
out="$(pc check --offline --no-build --allow-dirty 2>&1)"; eq "undeclared dependency is a warning, not an error" $? 0
has "warns where-from is missing" "'nowhere' is in the manifest's dependencies but nothing says where to get it" "$out"
has "warns about self dependency" "demo lists itself as a dependency" "$out"
git checkout -q manifest.json

# the version goes to the top level even if a nested "version" comes first
printf '# c3l.lock v1\ndcb\tregistry\thttp://example.invalid\tacme/dcb\t1.2.0\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tdirect\t-\n' > c3l.lock
sed -i 's|"provides" : "demo",|"targets-note" : { "version" : "9" },\n  "provides" : "demo",|' manifest.json
c3l pack --no-build --allow-dirty --output "$WORK/nested.c3l" >/dev/null 2>&1; eq "pack with a nested version rc" $? 0
flat="$(unzip -p "$WORK/nested.c3l" manifest.json | flat)"
has "nested version untouched" "^targets-note.version	9" "$flat"
has "top-level version set" "^version	" "$flat"
rm -f c3l.lock; git checkout -q manifest.json

out="$(pc publish --token-file "$WORK/token" 2>&1)"; eq "new package needs description rc" $? 1
has "description message" "description is required" "$out"
out="$(pc publish --description "Demo" 2>&1)"; eq "no token rc" $? 1
has "no token message" "no API token" "$out"
out="$(pc publish --token-file "$WORK/badtoken" --description Demo 2>&1)"; eq "bad token rc" $? 1
has "bad token message" "rejected the token" "$out"
out="$(pc --dry-run publish --token-file "$WORK/token" --description Demo 2>&1)"; eq "dry run rc" $? 0
has "dry run text" "would publish demo 1.0.0" "$out"
check_not "dry run uploaded nothing" curl -fs "$PR/api/v1/packages/demo/versions"
out="$(pc publish --token-file "$WORK/token" --description Demo --license MIT 2>&1)"; eq "publish rc" $? 0
has "publish ok and verified" "registry checksum matches" "$out"
check_not "token not printed" grep -q c3p_test <<< "$out"
out="$(pc publish --token-file "$WORK/token" 2>&1)"; eq "republish rc" $? 1
has "immutable" "already published" "$out"
out="$(C3L_TOKEN=c3p_test pc publish --version 1.0.1 2>&1)"; eq "token from env, --version rc" $? 0
has "tag vs --version warning" "says 1.0.0, but --version says 1.0.1" "$out"
check_not "no token: no request is sent after the error" grep -q "rejected the token" <<< "$(pc publish --description Demo 2>&1)"
out="$(C3PKG_TOKEN=c3p_test pc publish --version 1.0.2 2>&1)"; eq "C3PKG_TOKEN is used rc" $? 0
has "C3PKG_TOKEN publishes" "registry checksum matches" "$out"
out="$(C3PKG_TOKEN=c3p_wrong pc publish --version 1.0.3 2>&1)"; eq "wrong C3PKG_TOKEN rc" $? 1
has "wrong C3PKG_TOKEN rejected" "rejected the token" "$out"
out="$(C3L_TOKEN=c3p_wrong C3PKG_TOKEN=c3p_test pc publish --version 1.0.3 2>&1)"; eq "C3L_TOKEN wins over C3PKG_TOKEN rc" $? 1
out="$(C3L_TOKEN=c3p_wrong C3PKG_TOKEN=c3p_test pc publish --token-file "$WORK/token" --version 1.0.3 2>&1)"; eq "--token-file wins over both rc" $? 0

# manifest.json disagrees with the tag: warn, the tag wins
sed -i 's|"provides" : "demo",|"provides" : "demo",\n  "version" : "0.0.9",|' manifest.json
git commit -qam "manifest version"; git tag v1.2.0
out="$(pc publish --token-file "$WORK/token" --c3-version 0.7.1 2>&1)"; eq "publish with mismatching manifest rc" $? 0
has "manifest mismatch warning" "manifest.json says version 0.0.9, publishing 1.2.0" "$out"
curl -fs "$PR/download/me/demo@1.2.0" > "$WORK/dl.c3l"
has "archive carries tag version" '"version" : "1.2.0"' "$(unzip -p "$WORK/dl.c3l" manifest.json)"
has "repo manifest untouched" '"version" : "0.0.9"' "$(cat manifest.json)"

out="$(c3l --registry "$C3L_REGISTRY" publish --token-file "$WORK/token" 2>&1)"; eq "static registry publish rc" $? 1
has "read-only message" "read-only" "$out"
out="$(c3l --registry "http://127.0.0.1:$PKG429" --registry-type c3pkg publish --token-file "$WORK/token" --version 3.0.0 --description D 2>&1)"; eq "rate limit rc" $? 1
has "rate limit message" "retry in 7 seconds" "$out"

section "version from project.json; manifest.json wins; tag and --version win over both"
rm -rf "$WORK/pubver"; mkdir -p "$WORK/pubver"; cd "$WORK/pubver" && "$C3C" init-lib vdemo >/dev/null 2>&1 && cd vdemo.c3l || exit 1
mkdir -p src; printf 'module vdemo;\nfn int answer() => 42;\n' > src/vdemo.c3
printf '{ "version": "0.3.0", "authors": [], "sources": ["src/**"] }\n' > project.json
git init -q .; git add -A; git commit -qm init
out="$(pc check --offline --no-build 2>&1)"; eq "project.json version used rc" $? 0
has "version from project.json" "vdemo 0.3.0 (from project.json" "$out"
sed -i 's|"provides" : "vdemo",|"provides" : "vdemo",\n  "version" : "0.4.0",|' manifest.json; git commit -qam manifest
out="$(pc check --offline --no-build 2>&1)"; eq "manifest and project.json differ rc" $? 0
has "manifest.json wins" "vdemo 0.4.0 (from manifest.json" "$out"
has "project.json mismatch warned" "project.json says version 0.3.0, publishing 0.4.0" "$out"
git tag v1.0.0
out="$(pc check --offline --no-build 2>&1)"
has "tag wins over both" "vdemo 1.0.0 (from git tag v1.0.0" "$out"
has "manifest warned about" "manifest.json says version 0.4.0, publishing 1.0.0" "$out"
has "project.json warned about" "project.json says version 0.3.0, publishing 1.0.0" "$out"
out="$(pc check --offline --no-build --version 2.0.0 2>&1)"; has "--version wins" "vdemo 2.0.0 (from --version" "$out"
c3l pack --no-build --output "$WORK/vd.c3l" >/dev/null 2>&1
has "archive manifest gets the chosen version" '"version" : "1.0.0"' "$(unzip -p "$WORK/vd.c3l" manifest.json)"
has "project.json untouched" '"version": "0.3.0"' "$(cat project.json)"

section "install-side compatibility (c3_version, targets)"
cd "$WORK" && newproj p7
c3l --registry "$PR" init >/dev/null 2>&1
out="$(c3l --registry "$PR" add me/demo@1.0.0 2>&1)"; eq "compatible add rc" $? 0
check_not "no warning for matching C3" grep -q "published for C3" <<< "$out"
c3l --registry "$PR" remove demo >/dev/null 2>&1
out="$(c3l --registry "$PR" add me/demo@1.2.0 2>&1)"; eq "other-C3 add (warn) rc" $? 0
has "C3 mismatch warns" "published for C3 0.7.1" "$out"
c3l --registry "$PR" remove demo >/dev/null 2>&1
out="$(c3l --registry "$PR" --strict add me/demo@1.2.0 2>&1)"; eq "--strict add rc" $? 1
has "strict refuses" "not compatible" "$out"
check_not "nothing installed under --strict" test -e lib/demo.c3l

section "library mode: a directory with only manifest.json can add, list, remove, prune"
rm -rf "$WORK/libm"; mkdir -p "$WORK/libm"; cd "$WORK/libm" && "$C3C" init-lib lm >/dev/null 2>&1 && cd lm.c3l || exit 1
mkdir -p src; printf 'module lm;\nfn int answer() => 42;\n' > src/lm.c3
printf 'lib/\n' > .gitignore
git init -q .; git add -A; git commit -qm init; git tag v0.1.0
publish acme/lmc 1.0.0 >/dev/null
publish acme/lmb 1.0.0 --requires=acme/lmc:1.0.0 >/dev/null
out="$(c3l list 2>&1)"; eq "list in a library directory rc" $? 0
out="$(c3l init 2>&1)"; eq "init in a library directory rc" $? 0
out="$(c3l add acme/lmb 2>&1)"; eq "add in a library directory rc" $? 0
check "dependency in lib/" test -f lib/lmb.c3l
check "transitive dependency in lib/" test -f lib/lmc.c3l
flat="$(flat < manifest.json)"
has "manifest.json lists the direct dependency" "^dependencies\[0\]	lmb" "$flat"
check_not "manifest.json does not list the transitive one" grep -q '"lmc"' manifest.json
eq "lock has both" "$(awk -F'\t' '$0 !~ /^#/ && $1 !~ /^@/' c3l.lock | wc -l)" "2"
check "verify in a library directory" c3l verify
has "list shows the dependency" "lmb " "$(c3l list)"
git add -A; git commit -qm "add dependencies"; git tag v0.1.1
out="$(c3l check 2>&1)"; eq "check with installed dependencies rc" $? 0
has "compile check sees lib/" "compiles" "$out"
c3l pack --no-build --output "$WORK/lm.c3l" >/dev/null 2>&1
check_not "installed dependencies are not packed" bash -c "unzip -l '$WORK/lm.c3l' | grep -q 'lib/'"
has "the lock is packed" 'acme/lmb' "$(unzip -p "$WORK/lm.c3l" c3l.lock)"
check "a committed c3l.lock and ignored lib/ do not make the tree dirty" c3l check --offline --no-build
publish acme/lm 0.1.1 --from="$WORK/lm.c3l" >/dev/null
newproj lmcons
c3l init >/dev/null 2>&1
out="$(c3l add acme/lm 2>&1)"; eq "add a published library that has a lock rc" $? 0
has "its locked dependency follows" "lmb installed for lm" "$out"
check "and that one's dependency too" test -f lib/lmc.c3l
cd "$WORK/libm/lm.c3l" || exit 1
rm -f lib/lmb.c3l lib/lmc.c3l
c3l sync >/dev/null 2>&1; eq "sync in a library directory rc" $? 0
check "sync restored lib/lmc.c3l" test -f lib/lmc.c3l
c3l sync --frozen >/dev/null 2>&1; eq "sync --frozen in a library directory: no false drift rc" $? 0
check_not "list does not flag transitive libraries" bash -c "'$C3L' list | grep -q not-in-project"
c3l remove lmb >/dev/null 2>&1
check_not "remove drops the manifest dependency" grep -q '"lmb"' manifest.json
c3l prune >/dev/null 2>&1
check_not "prune removed the transitive library" test -e lib/lmc.c3l

section "path dependencies: linked, transitive, never published"
newproj ppd
mkdir -p ../pl/src; printf '{ "provides": "pl", "sources": ["src/**"], "vendor": { "c3l": { "requires": [ { "name": "lmc", "source": "acme/lmc", "version": "1.0.0" } ] } } }\n' > ../pl/manifest.json
printf 'module pl;\nfn int one() => 1;\n' > ../pl/src/pl.c3
c3l init >/dev/null 2>&1
out="$(c3l add ../pl 2>&1)"; eq "add ../pl rc" $? 0
check "linked, not copied" test -L lib/pl.c3l
check "dependencies of the linked library are installed" test -f lib/lmc.c3l
eq "lock kind is path" "$(awk -F'\t' '$1=="pl"{print $2}' c3l.lock)" "path"
eq "lmc is a dependency" "$(awk -F'\t' '$1=="lmc"{print $8}' c3l.lock)" "dep"
check "verify with a path dependency" c3l verify
has "list shows path" "pl .*path" "$(c3l list)"
printf 'module pl;\nfn int one() => 1;\nfn int two() => 2;\n' > ../pl/src/pl.c3
check "edits are visible through the link" grep -q two lib/pl.c3l/src/pl.c3
out="$(c3l update 2>&1)"; eq "update skips path dependencies rc" $? 0
rm lib/pl.c3l; c3l sync >/dev/null 2>&1; eq "sync restores the link rc" $? 0
check "link restored" test -L lib/pl.c3l
c3l remove pl >/dev/null 2>&1
check_not "remove deletes the link" test -e lib/pl.c3l
check "remove leaves the directory alone" test -f ../pl/manifest.json
# a library depending on a local directory cannot be published
c3l add ../pl >/dev/null 2>&1; cp c3l.lock "$WORK/pl.lock"
cd "$WORK/libm/lm.c3l" && cp "$WORK/pl.lock" c3l.lock
out="$(c3l check --offline --no-build 2>&1)"; eq "publishing a path dependency fails rc" $? 1
has "path dependency explained" "is a local directory" "$out"
rm -f c3l.lock

section "'lib' is added to dependency-search-paths"
rm -rf "$WORK/nosp"; mkdir -p "$WORK/nosp/src"; cd "$WORK/nosp" || exit 1
printf '{ "langrev": "1", "authors": [], "version": "0.1.0", "sources": ["src/**"], "targets": { "app": { "type": "executable" } } }\n' > project.json
echo 'fn void main() {}' > src/main.c3
cp project.json "$WORK/nosp.before"
c3l init >/dev/null 2>&1; c3l list >/dev/null 2>&1
check "list does not edit the project" cmp -s project.json "$WORK/nosp.before"
out="$(c3l add acme/lmc 2>&1)"; eq "add without dependency-search-paths rc" $? 0
has "lib added to dependency-search-paths" '"dependency-search-paths"' "$(cat project.json)"
check "installed into lib/" test -f lib/lmc.c3l

section "sync and update keep going by default; --fail-fast stops"
newproj kg
c3l init >/dev/null 2>&1
publish acme/ka 1.0.0 >/dev/null; publish acme/kb 1.0.0 >/dev/null
c3l add acme/ka >/dev/null 2>&1; c3l add acme/kb >/dev/null 2>&1
rm -f lib/ka.c3l lib/kb.c3l; mv "$REG/download/acme/ka@1.0.0" "$WORK/ka.hidden"
out="$(c3l sync 2>&1)"; eq "sync with one failure rc" $? 1
check "the other library was restored" test -f lib/kb.c3l
has "summary names the failure" "could not restore 1 library: ka" "$out"
rm -f lib/kb.c3l
out="$(c3l --fail-fast sync 2>&1)"; eq "--fail-fast rc" $? 1
check_not "--fail-fast stopped before kb" test -e lib/kb.c3l
mv "$WORK/ka.hidden" "$REG/download/acme/ka@1.0.0"
c3l sync >/dev/null 2>&1; eq "sync works once fixed rc" $? 0
check "both restored" test -f lib/ka.c3l -a -f lib/kb.c3l
publish acme/ka 1.1.0 --badsum >/dev/null; publish acme/kb 1.1.0 >/dev/null
out="$(c3l update 2>&1)"; eq "update with one failure rc" $? 1
has "update summary" "could not update 1 library: ka" "$out"
eq "kb was updated anyway" "$(awk -F'\t' '$1=="kb"{print $5}' c3l.lock)" "1.1.0"
eq "ka stayed" "$(awk -F'\t' '$1=="ka"{print $5}' c3l.lock)" "1.0.0"
check "ka intact after its rollback" c3l verify

section "several registries in one lock"
mkdir -p "$REG/c3/v2"; python3 "$HERE/fakereg.py" "$REG/c3/v2" publish acme/mr2 1.0.0 >/dev/null
publish acme/mr1 1.0.0 >/dev/null
newproj mr
c3l init >/dev/null 2>&1
c3l add acme/mr1 >/dev/null 2>&1; eq "add from the default registry rc" $? 0
c3l --registry "$C3L_REGISTRY/c3/v2" add acme/mr2 >/dev/null 2>&1; eq "add from a second registry rc" $? 0
eq "mr1 origin" "$(awk -F'\t' '$1=="mr1"{print $3 " " $4}' c3l.lock)" "$C3L_REGISTRY acme/mr1"
eq "mr2 origin" "$(awk -F'\t' '$1=="mr2"{print $3 " " $4}' c3l.lock)" "$C3L_REGISTRY/c3/v2 acme/mr2"
rm -f lib/mr1.c3l lib/mr2.c3l
out="$(env -u C3L_REGISTRY "$C3L" sync 2>&1)"; eq "sync restores from both registries rc" $? 0
check "both restored" test -f lib/mr1.c3l -a -f lib/mr2.c3l
publish acme/mr1 1.1.0 >/dev/null; python3 "$HERE/fakereg.py" "$REG/c3/v2" publish acme/mr2 1.2.0 >/dev/null
out="$(env -u C3L_REGISTRY "$C3L" outdated 2>&1)"
has "outdated asks the first registry" "mr1 .*1.1.0" "$out"
has "outdated asks the second registry" "mr2 .*1.2.0" "$out"
env -u C3L_REGISTRY "$C3L" update >/dev/null 2>&1; eq "update rc" $? 0
eq "mr1 updated" "$(awk -F'\t' '$1=="mr1"{print $5}' c3l.lock)" "1.1.0"
eq "mr2 updated" "$(awk -F'\t' '$1=="mr2"{print $5}' c3l.lock)" "1.2.0"
eq "mr2 keeps its origin" "$(awk -F'\t' '$1=="mr2"{print $3}' c3l.lock)" "$C3L_REGISTRY/c3/v2"
out="$(c3l --registry "$C3L_REGISTRY/c3/v2" add acme/mr1 2>&1)"; eq "same name from another registry rc" $? 1
has "name clash explained" "already installed from registry:$C3L_REGISTRY acme/mr1" "$out"
# a dependency can name its registry; a registry nobody trusts yet is refused
python3 "$HERE/fakereg.py" "$REG/c3/v2" publish acme/mr3 1.0.0 >/dev/null
publish acme/mr4 1.0.0 --requires=acme/mr3:1.0.0 --reqreg="$C3L_REGISTRY/c3/v2" >/dev/null
newproj mr4p
c3l init >/dev/null 2>&1
out="$(c3l add acme/mr4 2>&1 </dev/null)"; eq "dependency from an unknown registry is refused rc" $? 1
has "refusal names the host" "not trusted" "$out"
out="$(c3l --allow-host 127.0.0.1 add acme/mr4 2>&1 </dev/null)"; eq "allowed registry rc" $? 0
eq "dependency came from its registry" "$(awk -F'\t' '$1=="mr3"{print $3}' c3l.lock)" "$C3L_REGISTRY/c3/v2"

section "vendor collection (vendor:<name>)"
VEN="$REG/vendor"; mkdir -p "$VEN/latest"
vendor_make() { # name content-marker [nodigest]: write the file and the API record for the vendor stub
	python3 -I - "$VEN" "$1" "$2" "${3:-}" <<'PY'
import hashlib, json, os, sys, zipfile
root, name, marker, nodigest = sys.argv[1:5]
f = os.path.join(root, "latest", name + ".c3l")
with zipfile.ZipFile(f, "w") as z:
    z.writestr("manifest.json", json.dumps({"provides": name}))
    z.writestr("marker", marker)
api = os.path.join(root, "api.json")
d = json.load(open(api)) if os.path.exists(api) else {"assets": []}
d["assets"] = [a for a in d["assets"] if a["name"] != name + ".c3l"]
a = {"name": name + ".c3l"}
if not nodigest:
    a["digest"] = "sha256:" + hashlib.sha256(open(f, "rb").read()).hexdigest()
d["assets"].append(a)
json.dump(d, open(api, "w"))
PY
}
vendor_make vz one; vendor_make vnd one nodigest
export C3L_VENDOR_URL="$C3L_REGISTRY/vendor/latest" C3L_VENDOR_API="$C3L_REGISTRY/vendor/api.json"
newproj vd
c3l init >/dev/null 2>&1
out="$(c3l add vendor 2>&1)"; has "lists the collection" "vendor:vz" "$out"
out="$(c3l add vendor:vz 2>&1)"; eq "add vendor rc" $? 0
check "installed" test -f lib/vz.c3l
has "registered" '"vz"' "$(cat project.json)"
VSUM="sha256:$(sha lib/vz.c3l)"
eq "lock line" "$(awk -F'\t' '$1=="vz"{print $2 " " $3 " " $4 " " $5 " " $6}' c3l.lock)" "vendor $C3L_VENDOR_URL vz latest $VSUM"
check "verify" c3l verify
has "list shows vendor:" "vz .*vendor:vz" "$(c3l list)"
out="$(c3l add vendor:nope 2>&1)"; eq "unknown vendor library rc" $? 1
has "unknown explained" "no vendor library 'nope'" "$out"
out="$(c3l add vendor:vz@1.0 2>&1)"; eq "vendor has no versions rc" $? 1
rm -f lib/vz.c3l; c3l sync >/dev/null 2>&1; eq "sync restores rc" $? 0
check "restored" test -f lib/vz.c3l
check "sync --frozen is clean" c3l sync --frozen
# the collection replaces a file: sync must refuse it, outdated must see it, update must re-pin
vendor_make vz two
rm -f lib/vz.c3l
out="$(c3l sync 2>&1)"; eq "changed upstream: sync fails rc" $? 1
has "mismatch explained" "vendor:vz changed upstream" "$out"
check_not "nothing left behind" test -e lib/vz.c3l
out="$(c3l outdated 2>&1)"; has "outdated sees the change" "vz .*latest.*-> HEAD@" "$out"
c3l update >/dev/null 2>&1; eq "update rc" $? 0
eq "update re-pins" "$(awk -F'\t' '$1=="vz"{print $6}' c3l.lock)" "sha256:$(sha lib/vz.c3l)"
check "verify after update" c3l verify
out="$(c3l outdated 2>&1)"; has "up to date again" "up to date" "$out"
# no digest in the listing: warn and record the download
out="$(c3l add vendor:vnd 2>&1)"; eq "no digest rc" $? 0
has "trust on first use warning" "no checksum is listed for vendor:vnd" "$out"
# a library can depend on a vendor library
publish acme/vuser 1.0.0 --requires=vendor:vz >/dev/null
newproj vd2
c3l init >/dev/null 2>&1
out="$(c3l --allow-host 127.0.0.1 add acme/vuser 2>&1 </dev/null)"; eq "dependency on vendor:vz rc" $? 0
eq "vz came in as a dep" "$(awk -F'\t' '$1=="vz"{print $2 "/" $8}' c3l.lock)" "vendor/dep"
eq "vuser requires vz" "$(awk -F'\t' '$1=="vuser"{print $9}' c3l.lock)" "vz"
unset C3L_VENDOR_URL C3L_VENDOR_API

section "git contents, path links, URL spellings, release tags"
newproj gc1
c3l init >/dev/null 2>&1
c3l add "file://$GR" >/dev/null 2>&1
python3 - lib/gitlib.c3l <<'PY'
import sys, zipfile
f = sys.argv[1]; z = zipfile.ZipFile(f); comment = z.comment
items = [(i, z.read(i)) for i in z.infolist()]; z.close()
w = zipfile.ZipFile(f, "w"); w.comment = comment
for i, d in items: w.writestr(i, b"module evil;\n" if i.filename.endswith(".c3") else d)
w.close()
PY
out="$(c3l verify 2>&1)"; eq "a file changed inside a git archive is found rc" $? 1
has "reported as modified" "gitlib: modified" "$out"
c3l sync >/dev/null 2>&1; check "sync restores it" c3l verify
out="$(c3l add "file://$GR/" 2>&1)"; eq "same repository, other spelling rc" $? 0
out="$(c3l add "file://$GR" "$(git -C "$GR" rev-parse HEAD | cut -c1-12)" 2>&1)"; eq "short commit rc" $? 1
has "short commit explained" "full 40-character hash" "$out"
publish acme/nm 1.0.0 --c3po="other|file://$GR" >/dev/null
out="$(c3l --allow-host file add acme/nm 2>&1)"; eq "required name differs from the library rc" $? 1
has "name mismatch explained" "but that library is 'gitlib'" "$out"
check "the installed gitlib is untouched" c3l verify
PR1="$WORK/prerel"; mkdir -p "$PR1"; cd "$PR1" || exit 1
git init -q . && git config commit.gpgsign false
echo '{ "provides": "prerel" }' > manifest.json; git add -A && git commit -qm a && git tag v0.2.0
echo '// next' >> manifest.json; git commit -qam b && git tag v0.10.0-rc.1
newproj gc2
c3l init >/dev/null 2>&1
out="$(c3l add "file://$PR1" 2>&1)"; has "release tag preferred over a prerelease" "installed prerel v0.2.0" "$out"
check_not "a prerelease is not offered as an update" bash -c "$C3L outdated | grep -q prerel"
mkdir -p "$WORK/mv/pathlib/src" "$WORK/mv/app"
printf '{ "provides": "pathlib", "sources": ["src/**"] }\n' > "$WORK/mv/pathlib/manifest.json"
cd "$WORK/mv/app" && "$C3C" init proj >/dev/null && cd proj || exit 1
c3l init >/dev/null 2>&1; c3l add ../../pathlib >/dev/null 2>&1
check_not "the link is relative" bash -c "readlink lib/pathlib.c3l | grep -q '^/'"
cp -a "$WORK/mv" "$WORK/mv2"; cd "$WORK/mv2/app/proj" || exit 1
check "a moved project with its local library verifies" c3l verify
rm -rf "$WORK/mv2/pathlib"
has "a missing local library is missing" "pathlib: missing" "$(c3l verify 2>&1)"
publish acme/tp 1.0.0 >/dev/null; publish acme/tc 1.0.0 --requires=acme/tp:1.0.0 >/dev/null
newproj gc3
c3l init >/dev/null 2>&1; c3l add acme/tc >/dev/null 2>&1; c3l remove tc >/dev/null 2>&1
has "the tree shows what nothing needs" "tp 1.0.0 (not needed" "$(c3l list --tree)"

section "a library shared through git passes on what its c3l.lock requires"
LG="$WORK/lockedlib"; mkdir -p "$LG/src"; cd "$LG" || exit 1
printf '{ "provides": "lockedlib", "sources": ["src/**"] }\n' > manifest.json
printf 'module lockedlib;\n' > src/lockedlib.c3
printf 'lib/\n' > .gitignore
publish acme/lup 1.0.0 >/dev/null
c3l init >/dev/null 2>&1; c3l add acme/lup@1.0.0 >/dev/null 2>&1
check "the library has its dependency" test -f lib/lup.c3l
check_not "nothing is written into manifest.json but the name" grep -q vendor manifest.json
git init -q . && git config commit.gpgsign false && git add -A && git commit -qm one && git tag v1.0.0
newproj lg1
c3l init >/dev/null 2>&1
out="$(c3l --allow-host file add "file://$LG" 2>&1)"; eq "add a library with a lock rc" $? 0
has "its locked dependency is installed" "lup installed for lockedlib" "$out"
has "at least the locked version" "^lup	registry	.*	1.0.0	.*	dep	" "$(cat c3l.lock)"
newproj tg1
python3 - <<'PY'
p = "project.json"; s = open(p).read()
open(p, "w").write(s.replace('"type": "executable"', '"type": "executable", "dependencies": [ "targetonly" ]', 1))
PY
c3l init >/dev/null 2>&1
has "a target's dependency is seen" "targetonly .*untracked" "$(c3l list)"
check_not "and verify reports it" c3l verify

section "update arguments, rollback, --force, limits, migrate errors"
publish acme/up 1.0.0 >/dev/null; publish acme/up 1.1.0 >/dev/null
newproj rv1
c3l init >/dev/null 2>&1
c3l add acme/up@1.0.0 >/dev/null 2>&1
out="$(c3l update up.c3l@1.1.0 2>&1)"; eq "update name.c3l@version rc" $? 0
has "switched" "^up	registry	.*	1.1.0	" "$(cat c3l.lock)"
out="$(c3l update up@ 2>&1)"; eq "empty version rc" $? 1
: > c3l.lock
c3l add acme/nope >/dev/null 2>&1
check "an empty lockfile is kept on rollback" test -e c3l.lock
c3l add acme/up >/dev/null 2>&1
BAD="$(printf 'a%.0s' $(seq 64))"
sed -i "s/^\(up	.*	\)sha256:[0-9a-f]*	sha256:[0-9a-f]*/\1sha256:$BAD	sha256:$BAD/" c3l.lock
rm -f lib/up.c3l; cp c3l.lock "$WORK/lock.bad"; touch -d 2001-01-01 c3l.lock
out="$(c3l sync --frozen 2>&1)"; eq "frozen sync with a failing restore rc" $? 1
check "--frozen leaves the lockfile alone" cmp -s c3l.lock "$WORK/lock.bad"
eq "--frozen does not touch the lockfile" "$(date -r c3l.lock +%Y)" "2001"
check_not "no backup debris" bash -c "ls -A lib | grep -q c3l-backup"
newproj rv4
printf '{ "langrev": "1", "sources": ["src/**"], "targets": { "app": { "type": "executable" } } }\n' > project.json
cp project.json "$WORK/project.rv4"
c3l add acme/nope >/dev/null 2>&1
check "a failed add also takes back the \"lib\" it added" cmp -s project.json "$WORK/project.rv4"
publish acme/fa 1.0.0 >/dev/null; publish acme/fb 1.0.0 --requires=acme/fa:1.0.0 >/dev/null
newproj rv2
c3l init >/dev/null 2>&1
out="$(C3L_MAX_DEPS=0 c3l add acme/fb 2>&1)"; eq "dependency limit rc" $? 1
has "limit explained" "more than 0 transitive libraries" "$out"
check_not "limit rolled back" test -e lib/fb.c3l
c3l add acme/fb >/dev/null 2>&1
out="$(c3l remove fa 2>&1)"; eq "required library rc" $? 1
c3l remove --force fa >/dev/null 2>&1; eq "remove --force rc" $? 0
check_not "removed with --force" test -e lib/fa.c3l
newproj rv3
printf '{"packages":[{"name":"a","repo":"o/a","origin":"gitlab","commit":"COMMIT"},{"name":"b","repo":"o/b","origin":"github"}]}\n' | sed "s/COMMIT/0123456789abcdef0123456789abcdef01234567/" > project.lock.json
out="$(c3l migrate 2>&1)"; eq "migrate with bad entries rc" $? 0
has "unknown origin skipped" "unknown c3po origin 'gitlab'" "$out"
has "entry without commit skipped" "skipping a c3po entry" "$out"
out="$(c3l migrate 2>&1)"; eq "migrate twice rc" $? 1
rm -f project.lock.json c3l.lock
out="$(c3l migrate 2>&1)"; eq "migrate without c3po lock rc" $? 1
# c3l 0.x: .c3l.deps, libraries cloned as directories
newproj rv5
git clone -q --depth 1 --branch v0.1.0 "file://$GR" lib/gitlib.c3l 2>/dev/null
printf 'gitlib.c3l lib/gitlib.c3l file://%s v0.1.0\nbroken\n' "$GR" > .c3l.deps
out="$(c3l migrate 2>&1)"; eq "0.x migrate rc" $? 0
has "0.x tag resolved to its commit" "^gitlib	git	file://$GR	-	v0.1.0	commit:$C1" "$(cat c3l.lock)"
has "bad 0.x line skipped" "skipping a .c3l.deps line" "$out"
check ".c3l.deps left alone" test -f .c3l.deps
c3l sync >/dev/null 2>&1; eq "sync after 0.x migrate rc" $? 0
check "clone replaced by an archive" test -f lib/gitlib.c3l
check "verified" c3l verify
newproj rv6
printf 'gitlib.c3l lib/gitlib.c3l file://%s v9.9.9\n' "$GR" > .c3l.deps
out="$(c3l migrate 2>&1)"; eq "0.x tag that is gone rc" $? 1
has "unresolvable tag explained" "fix or remove the line for gitlib in .c3l.deps" "$out"
check_not "no lock written" test -e c3l.lock

section "hostile names, pins and URLs are refused"
# a git library whose "provides" escapes lib/
EV="$WORK/evilrepo"; mkdir -p "$EV"; cd "$EV" || exit 1
git init -q . && git config commit.gpgsign false
echo '{ "provides": "/../../escaped" }' > manifest.json
git add -A && git commit -qm one
newproj red1
c3l init >/dev/null 2>&1
out="$(c3l add "file://$EV" 2>&1)"; eq "provides with a path rc" $? 1
has "provides explained" "not a valid library name" "$out"
check_not "nothing written outside lib/" test -e ../escaped.c3l
check_not "no staging debris" bash -c "ls -A lib | grep -v '^.gitkeep$' | grep -q ."
# a dependency name that would forge lock lines
publish acme/inj 1.0.0 --deps=$'ok,a\nevil\tgit\t/\t-\tHEAD' >/dev/null
out="$(c3l add acme/inj 2>&1)"; eq "forged name rc" $? 1
has "forged name explained" "not a valid library name" "$out"
check_not "no forged lock line" grep -q "^evil" c3l.lock
check_not "rolled back" test -e lib/inj.c3l
# a lock whose pin is a git option
printf '%s\nx\tgit\tfile://%s\t-\tHEAD\tcommit:--upload-pack=touch %s/PWNED;false\tcommit:x\tdirect\t-\n' "$(head -n1 c3l.lock)" "$GR" "$WORK" > c3l.lock
out="$(c3l sync 2>&1)"; eq "option as pin rc" $? 1
has "damaged lock explained" "invalid commit" "$out"
check_not "no command ran" test -e "$WORK/PWNED"
# a trusted-looking host that is not
publish acme/hb 1.0.0 --c3po="hx|http://127.0.0.1:$PORT?@github.com/x" >/dev/null
newproj red2
c3l init >/dev/null 2>&1
out="$(c3l add acme/hb </dev/null 2>&1)"; eq "disguised host rc" $? 1
has "real host named" "host '127.0.0.1' is not trusted" "$out"
out="$(c3l remove ../../etc 2>&1)"; eq "path as a name rc" $? 1

section "cli"
has "help" "reproducible dependencies" "$(c3l help)"
has "version" "^c3l [0-9][0-9.]*$" "$(c3l version)"
check_not "unknown command" c3l frobnicate
cd "$WORK" && mkdir -p empty && cd empty
check_not "outside project" c3l list
out="$(c3l list 2>&1)"; has "plain directory: project hint" "no project.json found" "$out"
section "update stays with compatible versions (same major; below 1.0 same minor)"
newproj maj
c3l init >/dev/null 2>&1
for v in 1.0.0 1.1.0 2.0.0; do publish acme/mj "$v" >/dev/null; done
publish acme/mjuser 1.0.0 --requires=acme/mj:1.0.0 >/dev/null
c3l add acme/mjuser >/dev/null 2>&1
has "outdated: next and the incompatible one" "^mj .*1.0.0 .*-> 1.1.0 .*(not compatible: 2.0.0)" "$(c3l outdated)"
out="$(c3l update 2>&1)"; eq "update rc" $? 0
has "update stays in major 1" "	1.1.0	" "$(grep '^mj	' c3l.lock)"
has "new major announced" "mj 2.0.0 is available" "$out"
cp c3l.lock "$WORK/lock.before"
out="$(c3l update mj@2.0.0 2>&1)"; eq "major conflict rc" $? 1
has "dependent named" "mjuser -> mj: mjuser asks for 1.0.0" "$out"
check "conflict rolled back" cmp -s c3l.lock "$WORK/lock.before"
check "verify after rollback" c3l verify
for v in 0.3.0 0.3.5 0.4.0; do publish acme/zz "$v" >/dev/null; done
c3l add acme/zz@0.3.0 >/dev/null 2>&1
has "0.x: a new minor is not compatible" "^zz .*0.3.0 .*-> 0.3.5 .*(not compatible: 0.4.0)" "$(c3l outdated)"
c3l update zz >/dev/null 2>&1
has "0.x: update stays in 0.3" "	0.3.5	" "$(grep '^zz	' c3l.lock)"

section "arguments are checked: version argument, unknown names, unreachable sources"
newproj args
c3l init >/dev/null 2>&1
c3l add acme/mj 1.0.0 >/dev/null 2>&1; eq "version as a second argument rc" $? 0
has "that version installed" "	1.0.0	" "$(grep '^mj	' c3l.lock)"
check_not "version in both forms" c3l add acme/mj@1.0.0 1.1.0
check_not "vendor library with a version" c3l add vendor:mj 1.0
out="$(c3l update nosuch 2>&1)"; eq "update unknown rc" $? 1
has "unknown named" "'nosuch' is not in" "$out"
sed -i "s|$C3L_REGISTRY|http://127.0.0.1:1|" c3l.lock
out="$(c3l outdated 2>&1)"; eq "outdated unreachable rc" $? 1
has "unknown is not up to date" "mj: cannot determine the newest version" "$out"

section "git: what git says, URLs with credentials, export-subst"
newproj gitmsg
c3l init >/dev/null 2>&1
out="$(c3l add "file://$WORK/no-such-repo" 2>&1)"; eq "missing repo rc" $? 1
has "git's reason shown" "; git: .*does not appear to be a git repository" "$out"
out="$(c3l add "https://me:secret@github.com/me/lib" 2>&1)"; eq "credentials rc" $? 1
has "credentials explained" "without credentials" "$out"
check_not "no secret in the lock" grep -q secret c3l.lock
ES="$WORK/es"; mkdir -p "$ES/src"; cd "$ES" || exit 1
git init -q . && git config commit.gpgsign false
echo '{ "provides": "es", "targets": {} }' > manifest.json
echo '* export-subst' > .gitattributes
echo '// $Format:%H %d$' > src/es.c3
git add -A && git commit -qm one
cd "$WORK/gitmsg/app" || exit 1
c3l add "file://$ES" >/dev/null 2>&1; eq "export-subst add rc" $? 0
has "placeholders kept" 'Format:%H %d' "$(python3 -c "import zipfile;print(zipfile.ZipFile('lib/es.c3l').read('src/es.c3').decode())")"

section "an interrupted install undoes itself"
mkdir -p "$WORK/slowbin" "$WORK/tmp"
printf '#!/bin/sh\nsleep 2\nexec %s "$@"\n' "$(command -v git)" > "$WORK/slowbin/git"; chmod +x "$WORK/slowbin/git"
newproj intr
c3l init >/dev/null 2>&1
cp c3l.lock "$WORK/lock.before"; cp project.json "$WORK/project.before"
TMPDIR="$WORK/tmp" PATH="$WORK/slowbin:$PATH" "$C3L" add "file://$GR" >/dev/null 2>&1 &
P=$!; sleep 0.5; kill -TERM "$P"; wait "$P"; eq "interrupted rc" $? 130
eq "nothing left in lib" "$(ls -A lib | grep -v gitkeep)" ""
eq "no temporary directories left" "$(ls -A "$WORK/tmp")" ""
check "lock unchanged" cmp -s c3l.lock "$WORK/lock.before"
check "project unchanged" cmp -s project.json "$WORK/project.before"

section "search: the registry and the vendor snapshot"
out="$(c3l search SQLite 2>&1)"; eq "search rc" $? 0
has "vendor snapshot, by description, any case" "^vendor:sqlite3 .*SQLite 3 database" "$out"
has "count includes vendor" "(1 of 1 shown)" "$out"
out="$(c3l search alpha 2>&1)"; has "registry index.json" "^acme/alpha .*test lib alpha" "$out"
out="$(c3l search tag:db 2>&1)"
if grep -q vendor: <<< "$out"; then fail "tag search lists vendor libraries: $out"; else ok; fi
out="$(c3l --registry http://127.0.0.1:1 search sdl3 2>&1)"; eq "unreachable registry rc" $? 1
has "vendor shown without the registry" "vendor:sdl3_ttf" "$out"

section "git submodules: adopted by migrate, checked out by sync, moved by update, never overwritten"
# git 2.38.1+ refuses file:// submodules unless allowed; the user's git config decides that, the test allows it
export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always GIT_CONFIG_KEY_1=commit.gpgsign GIT_CONFIG_VALUE_1=false GIT_CONFIG_KEY_2=advice.detachedHead GIT_CONFIG_VALUE_2=false
SR="$WORK/serp"; mkdir -p "$SR/src"; cd "$SR" || exit 1
git init -q .
echo '{ "provides": "serp", "version": "0.2.0", "targets": {} }' > manifest.json
echo 'module serp;' > src/serp.c3
git add -A && git commit -qm one && git tag v0.2.0; S1="$(git rev-parse HEAD)"
echo 'module serp; fn int x() => 1;' > src/serp.c3
git commit -qam two && git tag v0.2.1; S2="$(git rev-parse HEAD)"
# v0.2.2 requires a library that no registry has: updating to it must roll back
printf '# c3l.lock v1 - written by c3l, do not edit by hand\nghost\tregistry\t%s\tacme/ghost\t1.0.0\tsha256:%s\tsha256:%s\tdirect\t-\n' "$C3L_REGISTRY" "$BAD" "$BAD" > c3l.lock
git add -A && git commit -qm three && git tag v0.2.2
git checkout -q "$S2"
# a library developer keeps serp as a submodule, without c3l
LB="$WORK/subdev"; rm -rf "$LB"; mkdir -p "$LB"; cd "$LB" || exit 1
"$C3C" init-lib mylib >/dev/null 2>&1; mv mylib.c3l repo; cd repo || exit 1
git init -q . && git submodule add -q "file://$SR" lib/serp.c3l 2>/dev/null && git -C lib/serp.c3l checkout -q v0.2.0 && git add -A && git commit -qm init
out="$(c3l add "file://$SR" 2>&1)"; eq "add over an unmanaged submodule rc" $? 1
has "add points to migrate" "'c3l migrate' adopts it" "$out"
check "submodule untouched by the refused add" test -f lib/serp.c3l/manifest.json
out="$(c3l migrate 2>&1)"; eq "migrate adopts rc" $? 0
has "adopted message" "adopted the submodule lib/serp.c3l: serp v0.2.0" "$out"
has "locked at the recorded commit, with the tag as version" "^serp	git	file://$SR	-	v0.2.0	commit:$S1	content:" "$(cat c3l.lock)"
has "list marks it" "^serp .*ok,submodule" "$(c3l list)"
check "verify" c3l verify
# the same content hash as an archive of that commit
newproj sm-arch; c3l init >/dev/null 2>&1; c3l add "file://$SR@v0.2.0" >/dev/null 2>&1
eq "content hash matches the archive's" "$(grep ^serp c3l.lock | cut -f7)" "$(grep ^serp "$LB/repo/c3l.lock" | cut -f7)"
cd "$LB/repo" && git add -A && git commit -qm "c3l"
check "check passes with the submodule" c3l check --offline --no-build --version 1.0.0

# someone clones without submodules: sync checks it out
cd "$LB" && rm -rf clone && git clone -q repo clone && cd clone || exit 1
check_not "not checked out after a plain clone" test -f lib/serp.c3l/manifest.json
has "verify: not checked out" "not checked out" "$(c3l verify 2>&1)"
out="$(c3l sync 2>&1)"; eq "sync checks out rc" $? 0
has "sync message" "checked out the submodule lib/serp.c3l at v0.2.0" "$out"
check "a directory, not an archive" test -f lib/serp.c3l/manifest.json
check "verify after sync" c3l verify
check "sync --frozen" c3l sync --frozen

# moved inside the submodule: sync goes back to the recorded commit, unless that drops commits
git -C lib/serp.c3l checkout -q "$S2"
has "verify: moved" "checked out at ${S2:0:12}, the repository records ${S1:0:12}" "$(c3l verify 2>&1)"
c3l sync >/dev/null 2>&1; eq "sync puts it back" "$(git -C lib/serp.c3l rev-parse HEAD)" "$S1"
echo '// wip' >> lib/serp.c3l/src/serp.c3 && git -C lib/serp.c3l commit -qam wip; WIP="$(git -C lib/serp.c3l rev-parse HEAD)"
out="$(c3l sync 2>&1)"; eq "sync with a commit on no branch rc" $? 1
has "sync keeps commits" "commits on no branch" "$out"
eq "commit still checked out" "$(git -C lib/serp.c3l rev-parse HEAD)" "$WIP"
git -C lib/serp.c3l checkout -q "$S1"
# local changes are never discarded
echo '// mine' >> lib/serp.c3l/src/serp.c3
has "verify: edited" "has local changes" "$(c3l verify 2>&1)"
out="$(c3l update serp 2>&1)"; eq "update with local changes rc" $? 1
has "update refuses" "not moving it" "$out"
check "edit kept" grep -q mine lib/serp.c3l/src/serp.c3
git -C lib/serp.c3l checkout -q -- .

# update moves the submodule and stages it; c3l never commits
out="$(c3l update serp@v0.2.1 2>&1)"; eq "update moves rc" $? 0
has "update message" "moved the submodule lib/serp.c3l from ${S1:0:12} to ${S2:0:12}" "$out"
eq "checked out at the new commit" "$(git -C lib/serp.c3l rev-parse HEAD)" "$S2"
has "lock follows" "^serp	git	.*	v0.2.1	commit:$S2	content:" "$(cat c3l.lock)"
has "staged, not committed" "^M  lib/serp.c3l" "$(git status --porcelain)"
check "verify after update" c3l verify
check "still a directory" test -d lib/serp.c3l
# a failing update leaves submodule, index and lock as they were
cp c3l.lock "$WORK/sm.lock"
out="$(c3l update serp@v0.2.2 2>&1)"; eq "failing update rc" $? 1
eq "submodule moved back" "$(git -C lib/serp.c3l rev-parse HEAD)" "$S2"
check "lock restored" cmp -s c3l.lock "$WORK/sm.lock"
eq "index back at the previous commit" "$(git ls-files -s lib/serp.c3l | cut -d' ' -f2)" "$S2"
check_not "no staging debris" bash -c "ls -A lib | grep -q part"
git commit -qam "serp 0.2.1"

# the repository records another commit than the lock
git -C lib/serp.c3l checkout -q "$S1" && git add lib/serp.c3l
out="$(c3l verify 2>&1)"; eq "lock differs rc" $? 1
has "both ways out" "c3l update serp@$S1' locks the submodule's commit, 'c3l update serp@v0.2.1' moves" "$out"
out="$(c3l sync 2>&1)"; eq "sync does not pick a side rc" $? 1
out="$(c3l check --offline --no-build --version 1.0.0 --allow-dirty 2>&1)"; eq "check catches it rc" $? 1
echo '// mine' >> lib/serp.c3l/src/serp.c3
out="$(c3l update "serp@$S1" 2>&1)"; eq "lock differs and edited: update refuses rc" $? 1
check "edit kept there too" grep -q mine lib/serp.c3l/src/serp.c3
git -C lib/serp.c3l checkout -q -- .
c3l update serp@v0.2.2 >/dev/null 2>&1; eq "failing update from there rc" $? 1
eq "index still at the staged commit" "$(git ls-files -s lib/serp.c3l | cut -d' ' -f2)" "$S1"
c3l update "serp@$S1" >/dev/null 2>&1; eq "update to the submodule's commit rc" $? 0
check "verify after locking the submodule's commit" c3l verify
has "commit label" "^serp	git	.*	commit:${S1:0:12}	commit:$S1	" "$(cat c3l.lock)"

# never overwritten or removed behind git's back
out="$(c3l remove serp 2>&1)"; eq "remove rc" $? 1
has "remove says git rm" "git rm lib/serp.c3l" "$out"
check "still there" test -f lib/serp.c3l/manifest.json
git rm -qf lib/serp.c3l && c3l remove serp >/dev/null 2>&1; eq "remove after git rm rc" $? 0
check_not "unlocked" grep -q ^serp c3l.lock

# consumers install the library: dependencies from its c3l.lock, as archives
newproj sm-use; c3l init >/dev/null 2>&1
out="$(c3l add "file://$LB/repo" 2>&1)"; eq "consumer add rc" $? 0
check "serp as an archive for the consumer" test -f lib/serp.c3l
check "consumer verify" c3l verify

# a library directory outside the project, with a space in its name
MO="$WORK/mono"; rm -rf "$MO"; mkdir -p "$MO"; cd "$MO" || exit 1
git init -q . && "$C3C" init app >/dev/null && git submodule add -q "file://$SR" "shared libs/serp.c3l" 2>/dev/null && git commit -qm init
cd app && sed -i 's|"dependency-search-paths": \[ *"lib" *\]|"dependency-search-paths": [ "../shared libs" ]|' project.json
out="$(c3l migrate 2>&1)"; eq "migrate outside the project rc" $? 0
has "adopted from ../shared libs" "adopted the submodule ../shared libs/serp.c3l" "$out"
check "verify outside the project" c3l verify

# a relative URL in .gitmodules cannot go into a lockfile
RL="$WORK/rel"; rm -rf "$RL"; mkdir -p "$RL"; cd "$RL" || exit 1
"$C3C" init-lib rl >/dev/null 2>&1; cd rl.c3l || exit 1
git init -q . && git submodule add -q ../../serp lib/serp.c3l 2>/dev/null && git commit -qm init
out="$(c3l migrate 2>&1)"; eq "relative URL rc" $? 1
has "relative URL explained" "relative to this repository's remote" "$out"
check_not "no lock written" test -s c3l.lock

# a nested repository git does not know about is not replaced while it holds work
newproj sm-nest; c3l init >/dev/null 2>&1
git clone -q "file://$SR" lib/serp.c3l && git -C lib/serp.c3l commit -q --allow-empty -m unpushed
out="$(c3l add "file://$SR@v0.2.0" 2>&1)"; eq "nested repository with work rc" $? 1
has "nested repository explained" "is a git repository with local changes or commits on no branch" "$out"
check "nested repository kept" test -d lib/serp.c3l/.git
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1 GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2

if [[ -n "$LIVE" ]]; then
	section "live: www.c3pkg.eu"
	unset C3L_REGISTRY
	newproj live
	c3l init >/dev/null 2>&1
	check "live add" c3l add jecokef902/box2d
	check "live verify" c3l verify
	has "live search" "tonis2/vk" "$(c3l search vk)"
	check "live add github.com/o/r" c3l add github.com/konimarti/serp.c3l@v0.2.0
	has "recorded as https" "	https://github.com/konimarti/serp.c3l	" "$(cat c3l.lock)"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
