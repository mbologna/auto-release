# How auto-release decides

A run finds the last release, asks the strategy whether a release is due, computes the
next version and, with `auto-release release`, pushes the tag and creates the Release. The
code is [`bin/auto-release`](../bin/auto-release); the variables are listed in the
[README](../README.md#configuration).

## The last release

The last release is the highest tag matching `vX.Y.Z`, with optional SemVer build metadata
(`v1.4.0+up2.15.3`), by version order. Pre-release tags such as `v1.3.0-rc1` are ignored.
With no such tag the run logs that and does nothing; push the first tag by hand. The
run fetches tags from `origin` first and falls back to the local ones when the fetch fails.

## Strategies

- `commits` (default) releases when any commit landed since the tag, or when a
  [fresh rebuild](#fresh-rebuilds) is due.
- `conventional` releases when a non-merge commit since the tag has a `feat`, `fix`,
  `perf` or `revert` type (with or without a scope), any type with `!`, or a
  `BREAKING CHANGE:` (or `BREAKING-CHANGE:`) footer. Without one, it releases a
  [maintenance release](#maintenance-releases) when that is due. A
  [fresh rebuild](#fresh-rebuilds) also releases. `docs`, `chore`, `ci`, `test`, `refactor`
  and the rest alone do not release.
- `security` runs on pushes to the default branch ([which ones](#the-security-strategy)
  depends on the forge) and releases only a CVE fix: a `fix(security)` commit, a
  [base image update](#base-image-updates) that fixes CVEs, or a
  [fresh rebuild](#fresh-rebuilds).

## The version

git-cliff computes the bump with the bundled rules: a breaking change (`type!:` or a
`BREAKING CHANGE:` footer) bumps the major, even before 1.0.0, a `feat` the minor and
anything else the patch. The run always bumps the patch for a maintenance release, and
when no commit landed since the tag (a fresh rebuild). When every
commit is one git-cliff skips, such as merges or `chore(release)`, git-cliff proposes no
bump and the run releases a patch.

## Upstream pins

A repository built on an upstream records the upstream version in the tag, as the
[versioning standard](https://github.com/mbologna/.github/blob/main/VERSIONING.md)
describes: `AUTO_RELEASE_METADATA_CMD`'s output becomes SemVer build metadata on the
version computed above. git-cliff carries the latest tag's metadata over, so the run
strips it and appends the current output. Build metadata does not take part in version
order, so the repository's own version still orders its releases.

The command runs in the checkout with `sh -c` and must print one line of build metadata
identifiers (`[0-9A-Za-z-]`, separated by dots). Anything else fails the run. When the output differs from what the latest tag
records, which includes the first release after a tag without it, `commits` and
`conventional` release: a pin bump from Renovate is often a `chore(deps)` commit, and the
tags should not lag behind it. `security` still releases only a CVE fix.

The image tag of such a release has no `+`, which OCI tags do not allow: `v1.4.0+up2.15.3`
is image `1.4.0`. The fresh rebuild check scans that tag.

Until 2.0.0, `AUTO_RELEASE_UPSTREAM_CMD` offered a second scheme, `v<upstream>+r<N>`, the
distribution packaging convention. It isn't SemVer and no repository uses it, so it was
removed; setting it now fails the run with a pointer to `AUTO_RELEASE_METADATA_CMD`.

## The security strategy

CI runs `security` on pushes to the default branch, so it decides from the commits and the
Dockerfiles alone; each case below releases at once. On GitHub the reusable workflow in
`mbologna/.github` runs it on every push. On GitLab the `ci-templates` component creates
the job only when the commit message contains `fix(security)` or the push changes a file
matching its `security_paths` input (Dockerfiles and dependency manifests by default). A
merge commit's message lists the merge request's commits when the project's merge commit
template includes `%{all_commits}`. Any other push creates no job and waits for the
scheduled run.

### `fix(security)` commits

A `fix(security)` or `fix(security)!` commit since the last tag, read from
`git log --no-merges`, releases. This is the title Renovate gives its vulnerability
updates. Other types with the same scope, such as `chore(security)` for a development-only
dependency, wait for the next scheduled release.

### Base image updates

For each Dockerfile in `AUTO_RELEASE_DOCKERFILES` (default `Dockerfile`, paths from the
repository root), auto-release reads the base image of the final stage at the last tag and
at `HEAD`: the image named by the last `FROM`, or, when that `FROM` names an earlier stage,
that stage's image. `${VAR}`, `${VAR:-default}` and `$VAR` take the defaults of the `ARG`
lines before the first `FROM`, and `--platform` and other flags are ignored.

When the reference changed, in tag or digest, Trivy scans both images from their
registries with the filter used everywhere else: vulnerabilities only,
`AUTO_RELEASE_SEVERITY` (default HIGH and CRITICAL), fixable ones only, minus the
checkout's `.trivyignore`. Findings in the old image that the new one lacks are the fixed
CVEs; if there are any, the run releases and lists them in the notes.

Nothing is built for this check. A Dockerfile missing at `HEAD` is skipped silently. One
added since the last tag, one that builds `FROM scratch`, one whose base depends on an
`ARG` with no default, or one whose images cannot be scanned is skipped with a log line, and
the run carries on.

The base image tag or digest has to change in the Dockerfile for the check to see it. A
floating tag such as `alpine:3` that moves upstream goes unnoticed, so pin digests and let
Renovate move them. The GitHub wrapper and the GitLab component take the list as their
`dockerfiles` input; on Forgejo, set `AUTO_RELEASE_DOCKERFILES` in the step's `env`.

Before 0.3.0 this check compared the image of the last version with the registry's
`latest`, which meant building and pushing `latest` on every push. `AUTO_RELEASE_IMAGE` now
matters only for the registry login and the fresh rebuild.

### Registry credentials

Trivy reads registry credentials from the Docker config (`~/.docker/config.json` or
`$DOCKER_CONFIG`) and its usual environment variables. Public base images on Docker Hub,
`ghcr.io`, `lscr.io` or `registry.gitlab.com` need none. auto-release logs in, with
`crane auth login`, only to the registry of `AUTO_RELEASE_IMAGE` or of an image in
`AUTO_RELEASE_IMAGES`: on GitLab with the job
token when `CI_REGISTRY` and `CI_JOB_TOKEN` are set, on GitHub with the forge token when the
image is on `ghcr.io`, and on Forgejo with the forge token when it is on the Forgejo host. A
failed login logs a warning and the scan runs anonymously.

## Fresh rebuilds

A Dockerfile that runs `apk add curl` or `apt-get install curl` without a version gets
whatever the distribution ships on the day of the build. When the distribution fixes a CVE
in one of those packages, nothing in the repository changes, so the checks above do not see
it. A fresh rebuild releases a patch, which builds the image from scratch (GitHub release
builds skip the layer cache; GitLab's kaniko builds never use one), when all of these hold:

- The last release tag is at least `AUTO_RELEASE_REBUILD_DAYS` days old (default 7; `0`
  turns the check off). A fix that is not out yet therefore costs at most one release per
  period.
- Trivy finds fixable findings, with the same filter as above, in the distribution
  packages of `${AUTO_RELEASE_IMAGE}:<last version>` that the final-stage base image named
  by the Dockerfile at the last tag does not have. Findings the base image shares need a
  base image update, unless the final stage upgrades its packages (`apt-get upgrade`,
  `apt upgrade`, `dist-upgrade` or `apk upgrade`, outside comments): then a rebuild fixes
  them too, and they count. Debian's and Alpine's official images are rebuilt only every
  week or few, so this ships a distribution's fix days to weeks sooner.
- Findings in language packages (pip, npm, Go modules) are left out: lock files and pinned
  versions make a rebuild produce the same ones.

The `security` strategy checks this on each push it runs on, and `commits` and
`conventional` on each run, so the weekly run releases even when no `feat` or `fix`
landed. The notes list each expected fix as CVE and package under "Security fixes in the
image".

The image has to be matched to its Dockerfile, so the check uses the one Dockerfile in
`AUTO_RELEASE_DOCKERFILES` that exists at the last tag. With several, or without
`AUTO_RELEASE_IMAGE`, it is skipped with a log line, as it is when the base image cannot be
resolved or either image cannot be scanned. A failed scan never fails the run.

### Several images

A repository that builds more than one image, say the application and a helper built
from a subdirectory, lists them in `AUTO_RELEASE_IMAGES` instead, each with the Dockerfile
it is built from:

```sh
AUTO_RELEASE_IMAGES="registry.example.com/app=Dockerfile registry.example.com/app/worker=worker/Dockerfile"
```

The list replaces `AUTO_RELEASE_IMAGE` and the single-Dockerfile rule above for this check;
the base image check still reads `AUTO_RELEASE_DOCKERFILES`.

Every image of a release is published with the same tag, so each one is scanned at the
image tag of the last release tag, and its findings are compared with the final-stage base
image of its own Dockerfile at that tag. One image with findings a rebuild should fix is
enough: a release builds them all, and the notes, under "Security fixes in the images",
name each image with its own list. An image that cannot be checked (its Dockerfile is not
in the last release, its base cannot be resolved, it or its base cannot be scanned, often
because that image was never pushed at that tag) is skipped with a log line, and the others
still count. An entry with a tag or digest fails the run, since the tag comes from the
release.

A build that reuses the images whose inputs did not change since the last release, rather
than building every image, would skip exactly the images a fresh rebuild is for. So the
release tag's message names them, one line each after the tag:

```text
v1.2.4

Fresh rebuild: registry.example.com/app/worker
```

On GitLab the tag pipeline reads the message as `CI_COMMIT_TAG_MESSAGE`, and ci-templates'
`kaniko-build` builds a listed image even when nothing it builds from changed.

Without the list, a quiet stretch with no commits left every image of such a repository on
the packages of its last build, since the single-image check cannot tell which Dockerfile
the image comes from.

The age comes from the tag. auto-release has pushed annotated tags since 0.4.0, which
record when they were made. A lightweight tag counts from its commit's date, which can only
be earlier, so the first fresh rebuild after an upgrade may come a few days early.

## Maintenance releases

Dependency updates are `chore(deps)` commits, which release nothing under `conventional`,
so in a quiet repository an update to a library or a base image could wait indefinitely for
a `feat` or `fix`. A `conventional` run with commits since the last tag but no `feat`,
`fix`, `perf`, `revert` or breaking commit releases a patch when both of these hold:

- Unreleased commits changed a runtime input: a file matching `AUTO_RELEASE_RUNTIME_PATHS`,
  by default `Dockerfile*`, `uv.lock`, `requirements*.txt`, `pyproject.toml`,
  `package.json`, `package-lock.json`, `go.mod`, `go.sum` and `composer.*`. A pattern
  without a `/` matches the file name in any directory (`Dockerfile*` covers
  `tools/Dockerfile`), one with a `/` the path from the repository root. The net change
  since the tag counts, so an update reverted before the run changes nothing. CI,
  documentation and development-tool files (`.github/`, `.gitlab-ci.yml`,
  `.pre-commit-config.yaml`) never release.
- The last release tag is at least `AUTO_RELEASE_MAINTENANCE_DAYS` days old (default 7;
  `0` turns maintenance releases off). With weekly dependency updates that is at most one
  maintenance release a week, and a repository whose runtime inputs did not change never
  rebuilds.

On GitLab the period can stretch to `AUTO_RELEASE_MAINTENANCE_DAYS_OVER_BUDGET` (default 28)
days when the namespace's CI minutes run short; see [ci-minutes.md](ci-minutes.md). The
`security` strategy never waits for this.

## Releasing

`auto-release release` creates an annotated, unsigned tag (a job container without a git
identity tags as `auto-release <auto-release@localhost>`) whose message is the tag, followed
by a `Fresh rebuild: IMAGE` line for each image a fresh rebuild is due for, pushes it, creates the Release
and, on GitHub and Forgejo, dispatches the tag build with `workflow_dispatch`. A tag pushed
with GitHub's `GITHUB_TOKEN` starts no workflow run, and Forgejo's automatic token behaves
the same way, so the dispatch is what builds the tag. The workflow is
`AUTO_RELEASE_DISPATCH_WORKFLOW`, else the file named in `GITHUB_WORKFLOW_REF` (on GitHub,
the calling workflow); with neither, the dispatch is skipped with a log line. GitLab needs
no dispatch: a tag pushed with a project or personal token starts a tag pipeline.

If creating the Release fails after the tag is pushed, the run still starts the tag build
and then fails, so the missing Release shows up as a failed job.

A `release` run on a tag ref (`GITHUB_REF` of `refs/tags/…`, or `CI_COMMIT_TAG`) does
nothing. The tag build that auto-release dispatches may be the workflow that called it,
and releases are cut from branches, so that run must not tag again.

On GitHub, the run writes `released` and `tag` to `GITHUB_OUTPUT` and the notes to the job
summary.
