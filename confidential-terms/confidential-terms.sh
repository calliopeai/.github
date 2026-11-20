#!/usr/bin/env bash
# confidential-terms.sh (calliopeai/.github)
#
# Fails when a change adds a confidential term, such as a client or agency
# name, to a repository. Terms are never printed: a finding names the place
# (file and line, commit, branch, pull request field) and the line of the
# term list that matched.
#
#   confidential-terms.sh ci                   scan a pull request or push (GitHub Actions)
#   confidential-terms.sh pre-commit           scan staged additions and the commit identity
#   confidential-terms.sh commit-msg FILE      scan a commit message
#   confidential-terms.sh install REPO...      copy this script into each REPO's hooks
#   confidential-terms.sh install-public ROOT  install into every clone under ROOT whose
#                                              origin is a public GitHub repository
#
# Installed as .git/hooks/pre-commit or .git/hooks/commit-msg, it takes its
# mode from the file name. CI reads the terms from $CLIENT_DENYLIST; the hooks
# read $CLIENT_DENYLIST_FILE (default ~/.config/calliope/client-denylist.txt).
# See README.md for the list format.
set -euo pipefail

marker='confidential-terms.sh (calliopeai/.github)'
tmp=''

die() {
  printf 'confidential-terms: %s\n' "$*" >&2
  exit 2
}

cleanup() {
  if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
}

make_tmp() {
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/confidential-terms.XXXXXX")
  trap cleanup EXIT
}

# True when $CLIENT_DENYLIST has at least one line that is not blank or a comment.
has_terms() {
  printf '%s\n' "${CLIENT_DENYLIST:-}" | grep -v '^[[:space:]]*#' | grep -q '[^[:space:]]'
}

is_zero() {
  case ${1:-0} in
    *[!0]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_commit() {
  [ -n "${1:-}" ] && git cat-file -e "$1^{commit}" 2>/dev/null
}

# Records are "where<TAB>line<TAB>text"; line is empty outside files.

# Lines a diff adds. Arguments go to git diff.
diff_records() {
  git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv --no-relative \
    -M --src-prefix=a/ --dst-prefix=b/ -U0 "$@" |
    LC_ALL=C awk '
      /^diff --git / { hunk = 0; next }
      !hunk && /^\+\+\+ / { path = substr($0, 5); sub(/^b\//, "", path); next }
      /^@@ / {
        hunk = 1
        n = $0
        sub(/^@@ -[0-9,]+ \+/, "", n)
        sub(/[^0-9].*$/, "", n)
        line = n + 0
        next
      }
      hunk && /^\+/ { print path "\t" line "\t" substr($0, 2); line++ }
    '
}

# Names of the files a diff adds or renames. Arguments go to git diff.
name_records() {
  git -c core.quotePath=false diff --no-relative --name-only --diff-filter=AR "$@" |
    LC_ALL=C awk '{ print $0 " (file name)\t\t" $0 }'
}

# Author, committer and message of each commit. Arguments go to git log.
commit_records() {
  git log --no-color --format='%x1e%h%x1f%an <%ae>%x1f%cn <%ce>%x1f%B' "$@" -- |
    LC_ALL=C awk '
      BEGIN { RS = "\036"; FS = "\037" }
      NF >= 4 {
        msg = $4
        for (i = 5; i <= NF; i++) msg = msg "\037" $i
        print "commit " $1 " author\t\t" $2
        print "commit " $1 " committer\t\t" $3
        n = split(msg, lines, "\n")
        for (i = 1; i <= n; i++) print "commit " $1 " message line " i "\t\t" lines[i]
      }
    '
}

# Match records against the terms. $1 is "github" (workflow commands) or
# "plain"; $2 is the records file. Exit 0: clean, 1: findings.
match_records() {
  CLIENT_DENYLIST=${CLIENT_DENYLIST:-} LC_ALL=C awk -v fmt="$1" '
    function matches(s, k,   t, off, p, b, a) {
      t = term[k]
      if (!whole[k]) return index(s, t) > 0
      off = 0
      while ((p = index(substr(s, off + 1), t)) > 0) {
        p += off
        b = p > 1 ? substr(s, p - 1, 1) : ""
        a = substr(s, p + length(t), 1)
        if ((b == "" || index(wordch, b) == 0) && (a == "" || index(wordch, a) == 0)) return 1
        off = p
      }
      return 0
    }
    # Replace every term in s with ***, longest first where two start together.
    function mask(s,   ls, out, k, p, best, len) {
      out = ""
      while (1) {
        ls = tolower(s)
        best = 0
        for (k = 1; k <= n; k++) {
          p = index(ls, term[k])
          if (p > 0 && (best == 0 || p < best || (p == best && length(term[k]) > len))) {
            best = p
            len = length(term[k])
          }
        }
        if (best == 0) return out s
        out = out substr(s, 1, best - 1) "***"
        s = substr(s, best + len)
      }
    }
    function data(s) { gsub(/%/, "%25", s); gsub(/\r/, "%0D", s); gsub(/\n/, "%0A", s); return s }
    function prop(s) { s = data(s); gsub(/:/, "%3A", s); gsub(/,/, "%2C", s); return s }
    function report(where, line, k,   loc) {
      found++
      if (found > max) return
      loc = mask(where)
      if (fmt == "github" && line != "")
        printf "::error file=%s,line=%s,title=Confidential term::%s line %s adds the term on line %d of the list\n", prop(loc), line, data(loc), line, src[k]
      else if (fmt == "github")
        printf "::error title=Confidential term::%s contains the term on line %d of the list\n", data(loc), src[k]
      else if (line != "")
        printf "%s:%s: adds the term on line %d of the list\n", loc, line, src[k]
      else
        printf "%s: contains the term on line %d of the list\n", loc, src[k]
    }
    BEGIN {
      wordch = "abcdefghijklmnopqrstuvwxyz0123456789"
      max = 50
      lines = split(ENVIRON["CLIENT_DENYLIST"], raw, "\n")
      for (i = 1; i <= lines; i++) {
        t = raw[i]
        sub(/\r$/, "", t)
        sub(/^[ \t]+/, "", t)
        sub(/[ \t]+$/, "", t)
        if (t == "" || substr(t, 1, 1) == "#") continue
        w = 0
        if (tolower(substr(t, 1, 5)) == "word:") {
          w = 1
          t = substr(t, 6)
          sub(/^[ \t]+/, "", t)
        }
        if (length(t) < 3) {
          if (fmt == "github") printf "::warning title=Confidential-term list::Line %d of the list is shorter than 3 characters and was ignored\n", i
          else printf "confidential-terms: line %d of the list is shorter than 3 characters and was ignored\n", i > "/dev/stderr"
          continue
        }
        n++
        term[n] = tolower(t)
        whole[n] = w
        src[n] = i
      }
    }
    {
      p = index($0, "\t")
      if (p == 0) next
      where = substr($0, 1, p - 1)
      rest = substr($0, p + 1)
      p = index(rest, "\t")
      if (p == 0) next
      line = substr(rest, 1, p - 1)
      text = tolower(substr(rest, p + 1))
      for (k = 1; k <= n; k++) if (matches(text, k)) report(where, line, k)
    }
    END {
      if (found > max) printf "... and %d more finding(s)\n", found - max
      exit (found ? 1 : 0)
    }
  ' "$2"
}

ci_mode() {
  if ! has_terms; then
    echo "::warning title=Confidential-term check skipped::CLIENT_DENYLIST is not available to this run (a fork or Dependabot pull request, or the organization secret is not set), so nothing was scanned."
    return 0
  fi
  [ "$(git rev-parse --is-shallow-repository)" = false ] ||
    die "the checkout is shallow; check out with fetch-depth: 0"

  local base='' head branch pr=0
  case "${CT_EVENT:-}" in
    pull_request)
      head=${CT_HEAD_SHA:?}
      branch=${CT_HEAD_REF:-}
      pr=1
      base=${CT_BASE_SHA:-}
      is_commit "$base" || base=$(git merge-base "origin/${CT_BASE_REF:?}" "$head") ||
        die "cannot find the base of the pull request"
      ;;
    push)
      head=${CT_AFTER:?}
      branch=${CT_REF:-}
      branch=${branch#refs/heads/}
      if is_zero "$head"; then
        echo "The push deleted a branch; nothing to scan."
        return 0
      fi
      if ! is_zero "${CT_BEFORE:-}" && is_commit "$CT_BEFORE"; then
        base=$CT_BEFORE
      elif [ "${CT_REF:-}" != "refs/heads/${CT_DEFAULT_BRANCH:-}" ]; then
        # A new branch: scan what it adds to the default branch.
        base=$(git merge-base "origin/${CT_DEFAULT_BRANCH:-}" "$head" 2>/dev/null) || base=''
      fi
      ;;
    *)
      echo "::warning title=Confidential-term check skipped::The ${CT_EVENT:-unknown} event is not supported, so nothing was scanned."
      return 0
      ;;
  esac

  make_tmp
  local records="$tmp/records" count scope
  {
    if [ -n "$base" ]; then
      diff_records "$base...$head"
      name_records "$base...$head"
      commit_records "$base..$head"
      count=$(git rev-list --count "$base..$head")
      scope="$count commit(s) after ${base:0:12}"
    else
      local empty
      empty=$(git hash-object -t tree /dev/null)
      diff_records "$empty" "$head"
      name_records "$empty" "$head"
      commit_records "$head"
      count=$(git rev-list --count "$head")
      scope="the full history ($count commit(s))"
    fi
    printf 'branch name\t\t%s\n' "$branch"
    if [ "$pr" = 1 ]; then
      printf 'pull request title\t\t%s\n' "${CT_PR_TITLE:-}"
      printf '%s\n' "${CT_PR_BODY:-}" | LC_ALL=C awk '{ print "pull request body line " NR "\t\t" $0 }'
    fi
  } > "$records"

  local rc=0
  match_records github "$records" || rc=$?
  case $rc in
    0)
      echo "No confidential terms in $scope up to ${head:0:12}."
      ;;
    1)
      echo "::error title=Confidential terms found::Remove each term above. In files, push a new commit. In commit messages, identities or the branch name, recreate the commits or branch without it. In the pull request title or body, edit it and the check runs again."
      return 1
      ;;
    *)
      die "matching failed (awk exit $rc)"
      ;;
  esac
}

# Load the hooks' term list into CLIENT_DENYLIST; false (with a note) when
# there is nothing to check.
load_local_terms() {
  local file=${CLIENT_DENYLIST_FILE:-$HOME/.config/calliope/client-denylist.txt}
  if [ ! -r "$file" ]; then
    printf 'confidential-terms: no term list at %s; check skipped.\n' "$file" >&2
    return 1
  fi
  CLIENT_DENYLIST=$(cat "$file")
  if ! has_terms; then
    printf 'confidential-terms: %s has no terms; check skipped.\n' "$file" >&2
    return 1
  fi
}

block_on_findings() {
  local rc=0
  match_records plain "$1" >&2 || rc=$?
  case $rc in
    0) return 0 ;;
    1)
      printf 'confidential-terms: commit blocked. Remove the term, or use --no-verify only for a false positive (CI checks again).\n' >&2
      return 1
      ;;
    *) die "matching failed (awk exit $rc)" ;;
  esac
}

pre_commit_mode() {
  load_local_terms || return 0
  make_tmp
  local ident
  {
    diff_records --cached
    name_records --cached
    if ident=$(git var GIT_AUTHOR_IDENT 2>/dev/null); then
      printf 'author identity\t\t%s\n' "${ident% * *}"
    fi
    if ident=$(git var GIT_COMMITTER_IDENT 2>/dev/null); then
      printf 'committer identity\t\t%s\n' "${ident% * *}"
    fi
  } > "$tmp/records"
  block_on_findings "$tmp/records"
}

commit_msg_mode() {
  [ -n "${1:-}" ] || die "commit-msg needs the message file"
  load_local_terms || return 0
  make_tmp
  # Drop the verbose diff below the scissors line, then git's comment lines.
  LC_ALL=C awk '/^. -+ >8 -+$/ { exit } { print }' "$1" |
    git stripspace --strip-comments |
    LC_ALL=C awk '{ print "commit message line " NR "\t\t" $0 }' > "$tmp/records"
  block_on_findings "$tmp/records"
}

install_mode() {
  [ $# -gt 0 ] || die "install needs at least one repository"
  local dir hooks hook hooks_path
  for dir in "$@"; do
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      printf '%s: not a git repository, skipped\n' "$dir" >&2
      continue
    fi
    if hooks_path=$(git -C "$dir" config --get core.hooksPath); then
      printf '%s: skipped, core.hooksPath is set (%s); call this script from those hooks instead\n' "$dir" "$hooks_path"
      continue
    fi
    hooks="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)/hooks"
    mkdir -p "$hooks"
    for hook in pre-commit commit-msg; do
      if [ -e "$hooks/$hook" ] && ! grep -qF "$marker" "$hooks/$hook"; then
        printf '%s: %s skipped, another hook is installed there\n' "$dir" "$hook"
        continue
      fi
      cp "$0" "$hooks/$hook"
      chmod 755 "$hooks/$hook"
      printf '%s: %s installed\n' "$dir" "$hook"
    done
  done
}

# owner/repo for a github.com remote URL; nothing for any other URL.
github_slug() {
  printf '%s\n' "$1" |
    sed -nE 's#^(git@github\.com:|ssh://git@github\.com/|https://([^@/]+@)?github\.com/)([^/]+/[^/]+)/?$#\3#p' |
    sed 's#\.git$##'
}

install_public_mode() {
  [ $# -eq 1 ] || die "install-public needs one directory"
  command -v gh >/dev/null 2>&1 || die "install-public needs the GitHub CLI (gh)"
  make_tmp
  : > "$tmp/visibility"
  local gitdir dir url slug vis out
  # A directory find cannot read is reported on stderr, not fatal.
  { find "$1" -maxdepth 5 \( -name node_modules -o -name .venv \) -prune -o -name .git -print -prune || true; } |
    while IFS= read -r gitdir; do
      dir=${gitdir%/.git}
      url=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
      slug=$(github_slug "$url")
      [ -n "$slug" ] || continue
      vis=$(awk -v s="$slug" '$1 == s { print $2; exit }' "$tmp/visibility")
      if [ -z "$vis" ]; then
        if out=$(gh api "repos/$slug" --jq .visibility 2>&1); then
          vis=$out
        elif printf '%s' "$out" | grep -q 'HTTP 404'; then
          vis=private
        else
          printf '%s: could not check %s (%s), skipped\n' "$dir" "$slug" "$out" >&2
          continue
        fi
        printf '%s %s\n' "$slug" "$vis" >> "$tmp/visibility"
      fi
      if [ "$vis" = public ]; then
        install_mode "$dir"
      fi
    done
}

usage() {
  sed -n '9,14p' "$0" | sed 's/^# //' >&2
}

main() {
  case "$(basename "$0")" in
    pre-commit)
      pre_commit_mode
      return
      ;;
    commit-msg)
      commit_msg_mode "$@"
      return
      ;;
  esac
  local mode=${1:-}
  if [ $# -gt 0 ]; then shift; fi
  case "$mode" in
    ci) ci_mode ;;
    pre-commit) pre_commit_mode ;;
    commit-msg) commit_msg_mode "$@" ;;
    install) install_mode "$@" ;;
    install-public) install_public_mode "$@" ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
