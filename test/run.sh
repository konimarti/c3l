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
# a git library is identified by its commit: the lock pins it, verify checks the
# commit id that `git archive` stores in the zip
check "lock records the commit as hash" grep -q '^gitlib.*commit:\([0-9a-f]*\).*commit:' c3l.lock
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
eq "dca is direct" "$(awk -F'\t' '$1=="dca"{print $7}' c3l.lock)" "direct"
eq "dcb is dep" "$(awk -F'\t' '$1=="dcb"{print $7}' c3l.lock)" "dep"
eq "dcb requires dcc" "$(awk -F'\t' '$1=="dcb"{print $8}' c3l.lock)" "dcc"
eq "lock has 8 columns" "$(awk -F'\t' '$1=="dca"{print NF}' c3l.lock)" "8"
check "verify ok" c3l verify
has "list shows dep" "dcb .*ok,dep" "$(c3l list)"
tree="$(c3l list --tree)"; has "tree root" "^dca 1.0.0" "$tree"; has "tree nested" "    dcc 1.0.0" "$tree"
why="$(c3l why dcc 2>&1)"; has "why dcc" "dcb requires dcc" "$why"; has "why chain" "dca requires dcb" "$why"
out="$(c3l remove dcb 2>&1)"; eq "remove needed dep refused" $? 1
has "refusal names dependent" "required by: dca" "$out"
check "dcb still there" test -f lib/dcb.c3l
c3l update dcb >/dev/null 2>&1
eq "update keeps role dep" "$(awk -F'\t' '$1=="dcb"{print $7}' c3l.lock)" "dep"
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
eq "dl is at 1.2.0" "$(awk -F'\t' '$1=="dl"{print $4}' c3l.lock)" "1.2.0"
check "diamond verify" c3l verify
newproj pd3
c3l init >/dev/null 2>&1; c3l add acme/dl@1.0.0 >/dev/null 2>&1
publish acme/dx 1.0.0 --requires=acme/dl:2.0.0 >/dev/null
cp c3l.lock "$WORK/lock.before"; cp project.json "$WORK/project.before"
out="$(c3l add acme/dx 2>&1)"; eq "major conflict rc" $? 1
has "conflict message" "version conflict" "$out"
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
eq "gitlib is a dep, git kind" "$(awk -F'\t' '$1=="gitlib"{print $2 "/" $7}' c3l.lock)" "git/dep"
check "c3po verify" c3l verify


section "review fixes: trust list, git constraint operators, vendor block placement"
eq "git ref: >= stripped" "$(git_ref_of '>=1.2.0')" "1.2.0"
eq "git ref: caret stripped" "$(git_ref_of '^v1.2.0')" "v1.2.0"
eq "git ref: plain tag kept" "$(git_ref_of 'v1.2.0')" "v1.2.0"
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
has "seali locked at HEAD" "^seali	git	https://github.com/Ecoral360/seali.c3l	HEAD	commit:$SHA40" "$(cat c3l.lock)"
has "codeberg mapped, tag kept" "^other	git	https://codeberg.org/o/other	v1.0.0	commit:$SHA40" "$(cat c3l.lock)"
newproj pd10
printf '# c3l.lock v1\nold\tregistry\tacme/old\t1.0.0\tsha256:aa\tsha256:aa\n' > c3l.lock
out="$(c3l list 2>&1)"; has "6-column line is readable" "old " "$out"
eq "6-column line defaults to direct" "$(source "$C3L"; LOCK=c3l.lock lock_entries | cut -f7)" "direct"

section "migrate from c3l 0.x"
newproj p6
mkdir -p lib; cp "$WORK/p5/app/lib/gitlib.c3l" lib/gitlib.c3l
echo "gitlib.c3l lib/gitlib.c3l file://$GR v0.2.0" > .c3l.deps
c3l migrate >/dev/null 2>&1; eq "migrate rc" $? 0
has "migrated line" "^gitlib.git.file://$GR.v0.2.0.commit:$C2" "$(cat c3l.lock)"
check "old file renamed" test -f .c3l.deps.migrated
check_not "migrate again refuses" c3l migrate

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

out="$(pc --offline check 2>&1)"; eq "untagged without version rc" $? 1
has "asks for a version" "no version" "$out"
git tag v1.1; out="$(pc --offline check 2>&1)"; eq "non-semver tag ignored" $? 1
git tag v1.0.0
out="$(pc --offline check 2>&1)"; eq "tagged check rc" $? 0
has "version from tag" "from git tag v1.0.0" "$out"
has "compile check ran" "compiles" "$out"
check_not "--version 1.0 rejected" pc --offline --version 1.0 check
check_not "build metadata rejected" pc --offline --version 1.0.0+b1 check

c3l pack --output "$WORK/a.c3l" >/dev/null 2>&1; eq "pack rc" $? 0
c3l pack --output "$WORK/b.c3l" >/dev/null 2>&1
eq "pack is deterministic" "$(sha "$WORK/a.c3l")" "$(sha "$WORK/b.c3l")"
has "archive manifest has version" '"version" : "1.0.0"' "$(unzip -p "$WORK/a.c3l" manifest.json)"
check_not "git metadata not packed" bash -c "unzip -l '$WORK/a.c3l' | grep -q '\.git/'"

echo dirty >> README.md
out="$(pc --offline check 2>&1)"; eq "dirty tree rc" $? 1
has "dirty message" "not clean" "$out"
check "--allow-dirty passes" pc --offline --allow-dirty check
git checkout -q README.md

# review fixes: unpacked junk is not "dirty"; modes do not depend on umask; nested .c3l is kept
mkdir -p obj tests; echo x > obj/a.o; echo x > c3l.lock
check "untracked obj/ and c3l.lock are not dirt" pc --offline --no-build check
echo x > tests/fixture.c3l; echo y > newfile.c3
check_not "untracked packaged file is dirt" pc --offline --no-build check
rm newfile.c3
( umask 002; c3l pack --no-build --allow-dirty --output "$WORK/u2.c3l" >/dev/null 2>&1 )
( umask 077; c3l pack --no-build --allow-dirty --output "$WORK/u7.c3l" >/dev/null 2>&1 )
eq "pack independent of umask" "$(sha "$WORK/u2.c3l")" "$(sha "$WORK/u7.c3l")"
has "nested .c3l kept" "tests/fixture.c3l" "$(unzip -l "$WORK/u2.c3l")"
check_not "obj/ and c3l.lock not packed" bash -c "unzip -l '$WORK/u2.c3l' | grep -q -e obj/ -e c3l.lock"
rm -rf obj c3l.lock tests
out="$(pc --offline check --version 2>&1)"; eq "--version without value rc" $? 1
has "--version message" "needs a value" "$out"

# publishing a library that has dependencies: vendor.c3l.requires comes from its own c3l.lock
printf '# c3l.lock v1\n@registry\thttp://example.invalid\ndcb\tregistry\tacme/dcb\t1.2.0\tsha256:aa\tsha256:aa\tdirect\t-\ndcc\tregistry\tacme/dcc\t1.0.0\tsha256:bb\tsha256:bb\tdep\t-\ngl\tgit\thttps://github.com/o/gl\tv0.3.0\tcommit:x\tcommit:x\tdirect\t-\n' > c3l.lock
c3l pack --no-build --output "$WORK/withdeps.c3l" >/dev/null 2>&1; eq "pack with a lockfile rc" $? 0
man="$(unzip -p "$WORK/withdeps.c3l" manifest.json)"
has "requires has the registry dependency" '"source": "acme/dcb", "version": "1.2.0"' "$man"
has "requires has the git dependency" '"source": "https://github.com/o/gl", "version": "v0.3.0"' "$man"
check_not "transitive-only libs are not listed" grep -q acme/dcc <<< "$man"
check_not "c3l.lock itself is not packed" bash -c "unzip -l '$WORK/withdeps.c3l' | grep -q c3l.lock"
has "repo manifest untouched" '"provides" : "demo"' "$(cat manifest.json)"
check_not "no requires without a lock" bash -c "unzip -p '$WORK/a.c3l' manifest.json | grep -q requires"
rm -f c3l.lock
sed -i 's|"provides" : "demo",|"provides" : "demo",\n  "dependencies" : [ "nowhere", "demo" ],|' manifest.json
out="$(pc --offline --no-build --allow-dirty check 2>&1)"; eq "undeclared dependency is a warning, not an error" $? 0
has "warns where-from is missing" "'nowhere' is in the manifest's dependencies but nothing says where to get it" "$out"
has "warns about self dependency" "demo lists itself as a dependency" "$out"
git checkout -q manifest.json

# vendor block goes to the top level even if a nested "version" comes first
printf '# c3l.lock v1\ndcb\tregistry\tacme/dcb\t1.2.0\tsha256:aa\tsha256:aa\tdirect\t-\n' > c3l.lock
sed -i 's|"provides" : "demo",|"targets-note" : { "version" : "9" },\n  "provides" : "demo",|' manifest.json
c3l pack --no-build --allow-dirty --output "$WORK/nested.c3l" >/dev/null 2>&1; eq "pack with a nested version rc" $? 0
flat="$(unzip -p "$WORK/nested.c3l" manifest.json | ( source "$C3L"; json_flatten ))"
has "vendor block at top level" "^vendor.c3l.requires\[0\].source	acme/dcb" "$flat"
has "nested version untouched" "^targets-note.version	9" "$flat"
has "top-level version set" "^version	" "$flat"
rm -f c3l.lock; git checkout -q manifest.json

out="$(pc --token-file "$WORK/token" publish 2>&1)"; eq "new package needs description rc" $? 1
has "description message" "description is required" "$out"
out="$(pc publish --description "Demo" 2>&1)"; eq "no token rc" $? 1
has "no token message" "no API token" "$out"
out="$(pc --token-file "$WORK/badtoken" publish --description Demo 2>&1)"; eq "bad token rc" $? 1
has "bad token message" "rejected the token" "$out"
out="$(pc --token-file "$WORK/token" --dry-run publish --description Demo 2>&1)"; eq "dry run rc" $? 0
has "dry run text" "would publish demo 1.0.0" "$out"
check_not "dry run uploaded nothing" curl -fs "$PR/api/v1/packages/demo/versions"
out="$(pc --token-file "$WORK/token" publish --description Demo --license MIT 2>&1)"; eq "publish rc" $? 0
has "publish ok and verified" "registry checksum matches" "$out"
check_not "token not printed" grep -q c3p_test <<< "$out"
out="$(pc --token-file "$WORK/token" publish 2>&1)"; eq "republish rc" $? 1
has "immutable" "already published" "$out"
out="$(C3L_TOKEN=c3p_test pc publish --version 1.0.1 2>&1)"; eq "token from env, --version rc" $? 0
has "tag vs --version warning" "says 1.0.0, but --version says 1.0.1" "$out"

# manifest.json disagrees with the tag: warn, the tag wins
sed -i 's|"provides" : "demo",|"provides" : "demo",\n  "version" : "0.0.9",|' manifest.json
git commit -qam "manifest version"; git tag v1.2.0
out="$(pc --token-file "$WORK/token" --c3-version 0.7.1 publish 2>&1)"; eq "publish with mismatching manifest rc" $? 0
has "manifest mismatch warning" "manifest.json says version 0.0.9, publishing 1.2.0" "$out"
curl -fs "$PR/download/me/demo@1.2.0" > "$WORK/dl.c3l"
has "archive carries tag version" '"version" : "1.2.0"' "$(unzip -p "$WORK/dl.c3l" manifest.json)"
has "repo manifest untouched" '"version" : "0.0.9"' "$(cat manifest.json)"

out="$(c3l --registry "$C3L_REGISTRY" --token-file "$WORK/token" publish 2>&1)"; eq "static registry publish rc" $? 1
has "read-only message" "read-only" "$out"
out="$(c3l --registry "http://127.0.0.1:$PKG429" --token-file "$WORK/token" --registry-type c3pkg publish --version 3.0.0 --description D 2>&1)"; eq "rate limit rc" $? 1
has "rate limit message" "retry in 7 seconds" "$out"

section "version from project.json; manifest.json wins; tag and --version win over both"
rm -rf "$WORK/pubver"; mkdir -p "$WORK/pubver"; cd "$WORK/pubver" && "$C3C" init-lib vdemo >/dev/null 2>&1 && cd vdemo.c3l || exit 1
mkdir -p src; printf 'module vdemo;\nfn int answer() => 42;\n' > src/vdemo.c3
printf '{ "version": "0.3.0", "authors": [], "sources": ["src/**"] }\n' > project.json
git init -q .; git add -A; git commit -qm init
out="$(pc --offline --no-build check 2>&1)"; eq "project.json version used rc" $? 0
has "version from project.json" "vdemo 0.3.0 (from project.json" "$out"
sed -i 's|"provides" : "vdemo",|"provides" : "vdemo",\n  "version" : "0.4.0",|' manifest.json; git commit -qam manifest
out="$(pc --offline --no-build check 2>&1)"; eq "manifest and project.json differ rc" $? 0
has "manifest.json wins" "vdemo 0.4.0 (from manifest.json" "$out"
has "project.json mismatch warned" "project.json says version 0.3.0, publishing 0.4.0" "$out"
git tag v1.0.0
out="$(pc --offline --no-build check 2>&1)"
has "tag wins over both" "vdemo 1.0.0 (from git tag v1.0.0" "$out"
has "manifest warned about" "manifest.json says version 0.4.0, publishing 1.0.0" "$out"
has "project.json warned about" "project.json says version 0.3.0, publishing 1.0.0" "$out"
out="$(pc --offline --no-build --version 2.0.0 check 2>&1)"; has "--version wins" "vdemo 2.0.0 (from --version" "$out"
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

section "cli"
has "help" "reproducible dependencies" "$(c3l help)"
has "version" "c3l 1" "$(c3l version)"
check_not "unknown command" c3l frobnicate
cd "$WORK" && mkdir -p empty && cd empty
check_not "outside project" c3l list
out="$(c3l list 2>&1)"; has "plain directory: project hint" "no project.json found" "$out"
mkdir -p "$WORK/libdir" && cd "$WORK/libdir" && echo '{ "provides": "x" }' > manifest.json
for cmd in list add verify sync outdated; do
	out="$(c3l $cmd acme/x 2>&1)"; eq "library dir: $cmd fails" $? 1
	has "library dir: $cmd explains" "is a library directory" "$out"
done
has "library dir: points to publish" "c3l publish" "$out"

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
