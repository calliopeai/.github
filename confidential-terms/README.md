# Confidential-term check

Keeps confidential terms, such as client and agency names, out of public
repositories. One script, `confidential-terms.sh`, runs in two places:

- **CI.** Every public repository has `.github/workflows/confidential-terms.yml`,
  a thin caller of `.github/workflows/reusable-confidential-terms.yml` in this
  repository. On each pull request and push it scans the lines the change adds,
  the names of added or renamed files, the new commits' messages and author and
  committer identities, the branch name, and the pull request title and body.
- **Local git hooks.** `pre-commit` scans staged additions, new file names and
  the commit identity; `commit-msg` scans the message.

The term list is never committed. CI reads it from the `CLIENT_DENYLIST`
organization secret, the hooks from `~/.config/calliope/client-denylist.txt`
(or the file named by `CLIENT_DENYLIST_FILE`). Findings never print a term:
they name the file and line (or commit, branch or pull request field) and the
line of the list that matched, so keep the secret and the local file
identical.

## List format

- One term per line, matched case-insensitively.
- A plain term matches anywhere, including inside longer words.
- `word:` before a term matches it only as a whole word: a letter or digit on
  either side stops the match. Use it for short or common words.
- Lines starting with `#` are comments; blank lines are ignored.
- Terms shorter than 3 characters are ignored with a warning.

## Organization secret

Set the secret in each organization that has public repositories, from the
local list:

```sh
gh secret set CLIENT_DENYLIST --org calliopeai --visibility all < ~/.config/calliope/client-denylist.txt
gh secret set CLIENT_DENYLIST --org ConflictHQ --visibility all < ~/.config/calliope/client-denylist.txt
gh secret set CLIENT_DENYLIST --org brocs-org --visibility all < ~/.config/calliope/client-denylist.txt
```

Until the secret exists, and on pull requests from forks or Dependabot (which
receive no secrets), the check passes with a warning that nothing was scanned.

## Adding the check to a repository

`.github/workflows/confidential-terms.yml`:

```yaml
# Fails a pull request or push that adds a confidential term.
# See confidential-terms/README.md in calliopeai/.github.
name: confidential-terms

on:
  pull_request:
    types: [opened, edited, reopened, synchronize]
  push:
    branches: ["**"]

permissions:
  contents: read

jobs:
  scan:
    uses: calliopeai/.github/.github/workflows/reusable-confidential-terms.yml@main
    secrets:
      CLIENT_DENYLIST: ${{ secrets.CLIENT_DENYLIST }}
```

The secret is passed by name rather than with `secrets: inherit`, which only
works within one organization and would hand over every other secret too.

The job is skipped in private repositories, where the terms legitimately
appear, so the caller can also live in a public template or in the private
source of a public mirror: it only runs once the code is public.

## Local hooks

From a clone of this repository, install into every clone under a directory
whose `origin` is a public GitHub repository (it asks `gh` for each
repository's visibility, so private client repositories, where those names
belong, are left alone):

```sh
confidential-terms/confidential-terms.sh install-public ~/repos
```

or into specific clones with `confidential-terms.sh install REPO...`. Each
hook is a copy of the script, so run the command again after cloning a public
repository or updating the script. A clone is skipped, with a note, when it
already has a hook of the same name that this script did not install, or when
it sets `core.hooksPath` (call the script from those hooks instead:
`confidential-terms.sh pre-commit` and `confidential-terms.sh commit-msg "$1"`).

A global `core.hooksPath` is deliberately not used: it would switch off every
repository's own `.git/hooks` (git-lfs, pre-commit) and still be bypassed by
repositories that set their own hooks path.

`git commit --no-verify` skips the hooks; CI still checks.

## Limits

- Only additions are checked. Terms already in a repository are not reported.
- Binary files are not scanned (their names are).
- Issues, comments and review text are not scanned.

## Tests

```sh
bash confidential-terms/test.sh
```

The tests use invented terms and run in CI through
`.github/workflows/confidential-terms.yml`, which also runs this branch's copy
of the check on this repository.
