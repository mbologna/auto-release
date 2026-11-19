# Release notes

git-cliff writes the notes from the bundled
[`share/auto-release/cliff.toml`](../share/auto-release/cliff.toml), and auto-release
puts them in the forge's Release object only. Nothing is committed to the repository.

## Groups

Commits since the last tag are grouped, newest first within each group, in this order:

1. Breaking changes: every `type!:` commit or `BREAKING CHANGE:` footer, with the footer's
   description when there is one. These commits also appear in their own group.
2. Features: `feat`.
3. Security: any type with the `security` scope.
4. Fixes: `fix`.
5. Performance: `perf`.
6. Reverts: `revert`.
7. Dependencies: `fix(deps)`, `chore(deps)` and `build(deps)`.
8. Other changes: everything else, including commits that do not follow Conventional
   Commits.

Each line shows the scope in bold (except `deps` and `security`), the first line of the
message and a link to the commit. The notes end with a compare link from the last tag to
the new one.

## What the notes leave out

- Merge commits: subjects starting `Merge branch`, `Merge pull request` or
  `Merge remote-tracking branch`, which covers the merge commits GitHub, GitLab and Forgejo
  create. Pull and merge requests merge with a merge commit on every forge, so the commits
  of the request appear individually. The `conventional` and `security` checks read
  `git log --no-merges` for the same reason.
- `chore(release)` commits.
- Renovate digest pins and lock-file refreshes: `(deps)` commits ending in `(digest)` or
  `(lockFileMaintenance)`, and `(deps): maintain …` commits. Version updates such as "from
  3.14.7 to 3.14.8" stay.

## Sections added by auto-release

Some releases start with a section that does not come from the commits:

- The `security` strategy lists the CVEs a base image update fixed under "Security fixes in
  the image", one line per CVE and package.
- A fresh rebuild lists, in the same section, the findings of the last release's image that
  a fresh build is expected to fix.
- A maintenance release starts with "Maintenance release" and the runtime inputs that
  changed since the last tag. Its `chore(deps)` commits appear under Dependencies as usual.
- When `AUTO_RELEASE_BASE_IMAGE_PATTERN` is set, the matching lines of the root
  `Dockerfile` follow under "Base image", in every release.

When no commit produced a line, the notes say "No commits since …" or "No notable changes
since …".

## A custom config

A repository can provide its own `cliff.toml` in the root, or point `AUTO_RELEASE_CONFIG`
at one. The tag pattern is always passed on the command line, so a custom config cannot
change which tags count as releases.
