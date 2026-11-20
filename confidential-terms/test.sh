#!/usr/bin/env bash
# Tests for confidential-terms.sh. Every term here is invented.
#
#   bash confidential-terms/test.sh
#
# Output of the script under test is captured and only shown, with its
# workflow commands defused, when a test fails, so its ::error:: lines never
# become annotations on this repository's own runs.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ct="$here/confidential-terms.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/confidential-terms-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Keep the machine's git configuration (hooks path, signing, diff prefixes) out.
export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1 HOME="$work/home"
mkdir -p "$HOME/.config/calliope"
git config --global user.name 'Test Author'
git config --global user.email 'author@example.invalid'
git config --global init.defaultBranch main
git config --global commit.gpgsign false

list="$HOME/.config/calliope/client-denylist.txt"
cat > "$list" <<'EOF'
# invented terms
zorblax
word:kreel
Quux Industries
ab
EOF
terms=$(cat "$list")
zero=0000000000000000000000000000000000000000

passed=0
failed=0
out=''
rc=0

# run DIR COMMAND...: run in DIR, keep the output in $out and the status in $rc.
run() {
  local dir=$1
  shift
  rc=0
  out=$(cd "$dir" && "$@" 2>&1) || rc=$?
}

bad() {
  failed=$((failed + 1))
  printf 'FAIL: %s\n' "$1"
  printf '%s\n' "$out" | sed -e 's/^::/: :/' -e 's/^/    /'
}

# expect NAME STATUS [TEXT...]: the last run exited with STATUS, printed each
# TEXT, and printed none of the invented terms.
expect() {
  local name=$1 want=$2 text
  shift 2
  if [ "$rc" != "$want" ]; then
    bad "$name: exit $rc, want $want"
    return
  fi
  for text in "$@"; do
    if ! printf '%s\n' "$out" | grep -qF -- "$text"; then
      bad "$name: missing \"$text\""
      return
    fi
  done
  if printf '%s\n' "$out" | grep -qiE 'zorblax|kreel|quux'; then
    bad "$name: printed a term"
    return
  fi
  passed=$((passed + 1))
}

# check NAME CONDITION...: a plain assertion.
check() {
  local name=$1
  shift
  if "$@"; then
    passed=$((passed + 1))
  else
    out=''
    bad "$name"
  fi
}

# add REPO FILE TEXT MESSAGE: append a line to FILE and commit it.
add() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >> "$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" commit -q --no-verify -m "$4"
}

# fresh NAME: a clone with origin/main, the way actions/checkout leaves one.
fresh() {
  git init -q "$work/$1-origin"
  add "$work/$1-origin" README.md 'hello' 'Initial commit'
  git clone -q "$work/$1-origin" "$work/$1"
  r="$work/$1"
}

sha() { git -C "$r" rev-parse HEAD; }

# ci_push BEFORE [REF]: the CI mode for a push of HEAD.
ci_push() {
  run "$r" env CLIENT_DENYLIST="$terms" CT_EVENT=push CT_REF="${2:-refs/heads/main}" \
    CT_DEFAULT_BRANCH=main CT_BEFORE="$1" CT_AFTER="$(sha)" "$BASH" "$ct" ci
}

# ci_pr BASE TITLE BODY [HEAD_REF]: the CI mode for a pull request from HEAD.
ci_pr() {
  run "$r" env CLIENT_DENYLIST="$terms" CT_EVENT=pull_request CT_BASE_SHA="$1" CT_BASE_REF=main \
    CT_HEAD_SHA="$(sha)" CT_HEAD_REF="${4:-feature}" CT_PR_TITLE="$2" CT_PR_BODY="$3" "$BASH" "$ct" ci
}

# --- CI: pushes ---------------------------------------------------------------

fresh push
base=$(sha)
add "$r" notes.txt 'a clean line' 'Add notes'
ci_push "$base"
expect 'push with a clean change passes' 0 'No confidential terms in 1 commit(s)'
expect 'short list entries are ignored with a warning' 0 \
  '::warning title=Confidential-term list::Line 5 of the list is shorter than 3 characters'

base=$(sha)
add "$r" notes.txt 'we met ZorBlax today' 'Update notes'
ci_push "$base"
expect 'an added line fails and names file and line' 1 \
  '::error file=notes.txt,line=2,title=Confidential term::notes.txt line 2 adds the term on line 2 of the list' \
  '::error title=Confidential terms found::'

base=$(sha)
printf 'a clean line\n' > "$r/notes.txt"
git -C "$r" commit -q --no-verify -am 'Trim notes'
ci_push "$base"
expect 'removing a term passes' 0

base=$(sha)
add "$r" notes.txt 'the skreeler tool' 'Add tool'
ci_push "$base"
expect 'a word-only term inside a longer word passes' 0

base=$(sha)
add "$r" notes.txt 'see kreel-app/setup' 'Add setup link'
ci_push "$base"
expect 'a word-only term on its own fails' 1 'notes.txt line 3 adds the term on line 3 of the list'

base=$(sha)
add "$r" docs/Zorblax-plan.md 'nothing to see' 'Add plan'
ci_push "$base"
expect 'an added file name fails, masked' 1 \
  '::error title=Confidential term::docs/***-plan.md (file name) contains the term on line 2 of the list'

base=$(sha)
printf 'zorblax\000\001\002' > "$r/blob.bin"
git -C "$r" add blob.bin
git -C "$r" commit -q --no-verify -m 'Add blob'
ci_push "$base"
expect 'binary content is not scanned' 0

base=$(sha)
GIT_AUTHOR_EMAIL=dev@zorblax.example add "$r" notes.txt 'fine' 'Add line'
ci_push "$base"
expect 'an author identity fails' 1 'author contains the term on line 2 of the list'

base=$(sha)
add "$r" notes.txt 'fine again' "$(printf 'Add another line\n\nAsked for by Quux  Industries? no, by QUUX INDUSTRIES')"
ci_push "$base"
expect 'a commit message fails with its line' 1 'message line 3 contains the term on line 4 of the list'

ci_push "$base" refs/heads/fix/zorblax-login
expect 'a branch name fails' 1 'branch name contains the term on line 2 of the list'

fresh preexisting
git -C "$r" switch -q -c feature
add "$r" old.txt 'zorblax was here before' 'Old line'
git -C "$r" push -q origin feature
base=$(sha)
add "$r" old.txt 'a new clean line' 'New line'
ci_push "$base" refs/heads/feature
expect 'a term already in the base is not reported' 0

fresh newbranch
git -C "$r" switch -q -c feature
add "$r" a.txt 'fine' 'Prepare for quux industries'
ci_push "$zero" refs/heads/feature
expect 'a new branch is scanned from the default branch' 1 'message line 1 contains the term on line 4 of the list'
ci_push 1111111111111111111111111111111111111111 refs/heads/feature
expect 'an unknown before (force push) falls back to the default branch' 1 'message line 1'

fresh firstpush
git -C "$r" commit -q --no-verify --allow-empty -m 'Zorblax kickoff'
ci_push "$zero"
expect 'a first push of the default branch scans the full history' 1 'message line 1 contains the term on line 2'

run "$r" env CLIENT_DENYLIST="$terms" CT_EVENT=push CT_REF=refs/heads/gone CT_DEFAULT_BRANCH=main \
  CT_BEFORE="$(sha)" CT_AFTER="$zero" "$BASH" "$ct" ci
expect 'a branch deletion has nothing to scan' 0 'deleted a branch'

# --- CI: pull requests --------------------------------------------------------

fresh pr
base=$(sha)
git -C "$r" switch -q -c feature
add "$r" a.txt 'fine' 'Add a'
ci_pr "$base" 'Add a' "$(printf 'Summary\n\nNothing special.')"
expect 'a clean pull request passes' 0 'No confidential terms in 1 commit(s)'

ci_pr "$base" 'Add a' "$(printf 'Summary\nFor QUUX INDUSTRIES only')"
expect 'a pull request body fails with its line' 1 'pull request body line 2 contains the term on line 4'

ci_pr "$base" 'Add zorblax support' ''
expect 'a pull request title fails' 1 'pull request title contains the term on line 2'

ci_pr "$base" 'Add a' '' kreel/login
expect 'a pull request branch name fails' 1 'branch name contains the term on line 3'

# --- CI: skips and errors -----------------------------------------------------

run "$r" env CLIENT_DENYLIST='' CT_EVENT=push "$BASH" "$ct" ci
expect 'a missing secret skips with a warning' 0 '::warning title=Confidential-term check skipped::'

run "$r" env CLIENT_DENYLIST="$(printf '# only\n\n  # comments\n')" CT_EVENT=push "$BASH" "$ct" ci
expect 'a list of comments skips with a warning' 0 '::warning title=Confidential-term check skipped::'

run "$r" env CLIENT_DENYLIST="$terms" CT_EVENT=workflow_dispatch "$BASH" "$ct" ci
expect 'an unsupported event skips with a warning' 0 'event is not supported'

base=$(sha)
add "$r" a.txt 'zorblax' 'Add more'
run "$r" env CLIENT_DENYLIST="$(printf 'other\r\nzorblax\r\n')" CT_EVENT=push CT_REF=refs/heads/feature \
  CT_DEFAULT_BRANCH=main CT_BEFORE="$base" CT_AFTER="$(sha)" "$BASH" "$ct" ci
expect 'a list with CRLF line ends still matches' 1 'adds the term on line 2 of the list'

git clone -q --depth 1 "file://$work/pr-origin" "$work/shallow"
run "$work/shallow" env CLIENT_DENYLIST="$terms" CT_EVENT=push "$BASH" "$ct" ci
expect 'a shallow checkout is an error' 2 'fetch-depth: 0'

# --- Hooks --------------------------------------------------------------------

r="$work/hooks"
git init -q "$r"
add "$r" README.md 'hi' 'Initial commit'

printf 'ZORBLAX\n' > "$r/a.txt"
git -C "$r" add a.txt
run "$r" "$BASH" "$ct" pre-commit
expect 'pre-commit blocks a staged term' 1 'a.txt:1: adds the term on line 2 of the list' 'commit blocked'
git -C "$r" rm -q --cached a.txt
rm "$r/a.txt"

printf 'fine\n' > "$r/b.txt"
git -C "$r" add b.txt
run "$r" "$BASH" "$ct" pre-commit
expect 'pre-commit passes a clean change' 0

run "$r" env GIT_AUTHOR_EMAIL=dev@zorblax.example "$BASH" "$ct" pre-commit
expect 'pre-commit blocks a term in the author identity' 1 'author identity: contains the term on line 2'

run "$r" env CLIENT_DENYLIST_FILE="$work/missing.txt" "$BASH" "$ct" pre-commit
expect 'pre-commit skips without a list' 0 'no term list at'

printf 'Fix the thing\n\n# zorblax only in a comment\n' > "$work/msg"
run "$r" "$BASH" "$ct" commit-msg "$work/msg"
expect 'commit-msg ignores comment lines' 0

printf 'Fix\n# ------------------------ >8 ------------------------\ndiff --git a/x b/x\n+zorblax\n' > "$work/msg"
run "$r" "$BASH" "$ct" commit-msg "$work/msg"
expect 'commit-msg ignores the verbose diff' 0

printf 'Fix the Zorblax thing\n' > "$work/msg"
run "$r" "$BASH" "$ct" commit-msg "$work/msg"
expect 'commit-msg blocks a term' 1 'commit message line 1: contains the term on line 2'

# --- Install ------------------------------------------------------------------

run "$work" "$BASH" "$ct" install "$r"
expect 'install adds both hooks' 0 'pre-commit installed' 'commit-msg installed'
check 'installed hooks are executable' test -x "$r/.git/hooks/pre-commit" -a -x "$r/.git/hooks/commit-msg"

printf 'zorblax\n' > "$r/c.txt"
git -C "$r" add c.txt
run "$r" git commit -q -m 'Add c'
expect 'the installed pre-commit hook blocks a commit' 1 'c.txt:1: adds the term' 'commit blocked'
git -C "$r" rm -q --cached c.txt
rm "$r/c.txt"

run "$r" git commit -q -m 'Mention Zorblax'
expect 'the installed commit-msg hook blocks a commit' 1 'commit message line 1: contains the term'

run "$r" git commit -q -m 'Add b'
expect 'the installed hooks let a clean commit through' 0

run "$work" "$BASH" "$ct" install "$r"
expect 'install replaces its own hooks' 0 'pre-commit installed'

git init -q "$work/foreign"
printf '#!/bin/sh\nexit 0\n' > "$work/foreign/.git/hooks/pre-commit"
run "$work" "$BASH" "$ct" install "$work/foreign"
expect 'install leaves another hook alone' 0 'pre-commit skipped, another hook is installed there' 'commit-msg installed'

git init -q "$work/hookspath"
git -C "$work/hookspath" config core.hooksPath .githooks
run "$work" "$BASH" "$ct" install "$work/hookspath"
expect 'install skips a repository with core.hooksPath' 0 'skipped, core.hooksPath is set'

mkdir -p "$work/bin" "$work/root/nested"
cat > "$work/bin/gh" <<'EOF'
#!/bin/sh
# Stub: acme/open is public, every other repository is not found.
case "$2" in
  repos/acme/open) echo public ;;
  *) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
esac
EOF
chmod 755 "$work/bin/gh"
for spec in 'open git@github.com:acme/open.git' 'nested/copy https://github.com/acme/open/' \
  'closed https://github.com/acme/closed' 'elsewhere https://gitlab.com/acme/open.git'; do
  dir=${spec%% *}
  git init -q "$work/root/$dir"
  git -C "$work/root/$dir" remote add origin "${spec#* }"
done
run "$work" env PATH="$work/bin:$PATH" "$BASH" "$ct" install-public "$work/root"
expect 'install-public installs into public clones' 0 'open: pre-commit installed' 'copy: commit-msg installed'
check 'install-public skips private and non-GitHub clones' \
  test ! -e "$work/root/closed/.git/hooks/pre-commit" -a ! -e "$work/root/elsewhere/.git/hooks/pre-commit"

printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
