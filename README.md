# auto-release

`auto-release` tags the next semantic version of a repository and publishes a Release with grouped notes. No release pull request and no human step are involved. One shell script and one container image run on GitHub Actions, GitLab CI and Forgejo Actions, taking their inputs from the job environment.

It keeps what the earlier tools each did well. Like the old `auto-release` workflows, it releases on a schedule as soon as something changed. Like release-please, it derives the version from [Conventional Commits](https://www.conventionalcommits.org/) and writes notes grouped by change type. The notes live only in the forge's Release object. Nothing is committed back to the default branch, so the job needs no branch-protection bypass.

## How a run decides

1. The latest tag matching `vX.Y.Z` is the last release. Pre-release tags such as `v1.3.0-rc1` are ignored. With no such tag the run does nothing; push the first tag by hand.
2. The strategy decides whether a release is due:

   | Strategy | Releases when |
   |---|---|
   | `commits` (default) | any commit landed since the tag, or a [fresh rebuild](#fresh-rebuilds) is due |
   | `conventional` | a `feat`, `fix`, `perf` or `revert` commit, or a breaking change, landed since the tag, a [maintenance release](#maintenance-releases) is due (dependency updates to runtime inputs, once the last release is a week old), or a [fresh rebuild](#fresh-rebuilds) is due; `docs`, `chore`, `ci` and the rest alone do not release |
   | `docker` | the registry's `latest` image digest differs from the image tagged with the last version, or that version was never published |
   | `security` | a `fix(security)` commit landed (Renovate's CVE updates), the base image of a Dockerfile changed and the new one no longer has fixable HIGH/CRITICAL [Trivy](https://trivy.dev/) findings that the old one has, or a [fresh rebuild](#fresh-rebuilds) is due; the notes list those CVEs. See [The security strategy](#the-security-strategy) |

3. [git-cliff](https://git-cliff.org/) computes the bump. A breaking change (`type!:` or a `BREAKING CHANGE:` footer) bumps the major, even before 1.0.0. A `feat` bumps the minor, and anything else the patch. `docker` and maintenance releases always bump the patch.
4. `auto-release release` pushes the tag (an annotated one, which records when it was made), creates the Release and, on GitHub and Forgejo, starts the tag build (see [Tokens](#tokens)). `auto-release plan` prints the version and notes and changes nothing.

## Release notes

The bundled [`share/auto-release/cliff.toml`](share/auto-release/cliff.toml) groups commits under Breaking changes, Features, Security (`*(security):`), Fixes, Performance, Reverts, Dependencies (`fix|chore|build(deps):`) and Other changes. Commits that do not follow Conventional Commits go under Other changes. Merge commits, `chore(release)` commits and Renovate digest and lock-file refreshes are left out. Each line links to its commit, and the notes end with a compare link.

The `security` strategy puts the CVEs that a base image update fixed under "Security fixes in the image" at the top, and a fresh rebuild lists there the CVEs it is expected to fix. A maintenance release starts with "Maintenance release" and the runtime inputs that changed; its `chore(deps)` commits are under Dependencies as usual. The `docker` strategy adds the new image digest there. When the base image pattern is set, the matching `Dockerfile` lines are added too.

A repository can provide its own `cliff.toml`, or point `AUTO_RELEASE_CONFIG` at one. The tag pattern is always passed on the command line.

## The security strategy

CI runs `security` on every push to the default branch, so it has to decide from the commit alone. Two things release at once:

- A `fix(security)` or `fix(security)!` commit since the last tag. This is the title Renovate gives its vulnerability updates. Other types with the same scope, such as `chore(security)` for a development-only dependency, wait for the next scheduled release.
- A base image update that fixes CVEs. For each Dockerfile in `AUTO_RELEASE_DOCKERFILES` (default `Dockerfile`), auto-release reads the base image of the final stage at the last tag and at `HEAD`. That is the image named by the last `FROM`, or by the stage it builds on when it is `FROM <stage>`. `${VAR}`, `${VAR:-default}` and `$VAR` take the defaults of the `ARG` lines before the first `FROM`, and `--platform` is ignored. When the reference changed, its tag or its digest, Trivy scans both images straight from their registries, with the same filter as everywhere else: vulnerabilities only, HIGH and CRITICAL, fixable ones, minus the checkout's `.trivyignore`. Findings in the old image that the new one does not have are the fixed CVEs. If there are any, the run releases and lists them.

Nothing is built for this check. A Dockerfile that is missing at `HEAD` is skipped silently. One added since the last tag, one that builds `FROM scratch`, one whose base depends on an `ARG` with no default, or one whose images cannot be scanned is skipped with a log line, and the run carries on.

Trivy reads registry credentials from the Docker config (`~/.docker/config.json` or `$DOCKER_CONFIG`) and its usual environment variables. Public base images on Docker Hub, `ghcr.io`, `lscr.io` or `registry.gitlab.com` need none. auto-release logs in to the project's own registry only, as before: on GitLab with the job token when `AUTO_RELEASE_IMAGE` (default `$CI_REGISTRY_IMAGE`) is there, on GitHub and Forgejo with the forge token when `AUTO_RELEASE_IMAGE` is on `ghcr.io` or the Forgejo host.

A repository with more than one image, or a Dockerfile outside the root, lists them all, separated by spaces or commas and relative to the repository root: `AUTO_RELEASE_DOCKERFILES: "Dockerfile tools/Dockerfile"`. The GitHub wrapper and the GitLab component take it as their `dockerfiles` input; on Forgejo, set it in the step's `env`. The base image tag or digest has to change in the Dockerfile for this check to see it. A floating tag such as `alpine:3` that moves upstream goes unnoticed, so pin digests and let Renovate move them.

Before 0.3.0 this check compared the image of the last version with the registry's `latest`, which meant building and pushing `latest` on every push. That comparison is gone: `AUTO_RELEASE_IMAGE` matters for the `docker` strategy, the registry login and the fresh rebuild below.

## Maintenance releases

Dependency updates are `chore(deps)` commits, which release nothing under `conventional`. Without more, an update to a library or a base image would wait for the next `feat` or `fix`, which in a quiet repository may never come. A scheduled `conventional` run with no `feat`, `fix`, `perf`, `revert` or breaking commit since the last tag therefore releases a patch when both of these hold:

- Unreleased commits changed a runtime input: a file matching `AUTO_RELEASE_RUNTIME_PATHS`, by default `Dockerfile*`, `uv.lock`, `requirements*.txt`, `pyproject.toml`, `package.json`, `package-lock.json`, `go.mod`, `go.sum` and `composer.*`. A pattern without a `/` matches the file name in any directory (`Dockerfile*` covers `tools/Dockerfile`), one with a `/` the path from the repository root. The net change since the tag counts, so an update reverted before the run changes nothing. CI, documentation and development-tool changes (`.github/`, `.gitlab-ci.yml`, `.pre-commit-config.yaml`) never release.
- The last release tag is at least `AUTO_RELEASE_MAINTENANCE_DAYS` days old (default 7, `0` turns maintenance releases off). With weekly dependency updates that is at most one maintenance release a week, and a repository whose runtime inputs did not change never rebuilds.

### On GitLab's CI minutes

Every release on GitLab runs a release build on the namespace's CI minutes (400 a month on the Free tier). When the month's use runs high, maintenance releases slow down from weekly to every four weeks. Before a maintenance release whose last tag is between `AUTO_RELEASE_MAINTENANCE_DAYS` and `AUTO_RELEASE_MAINTENANCE_DAYS_OVER_BUDGET` (default 28) days old, a GitLab run reads the namespace's `ciMinutesUsage` (GraphQL) for the current month. It projects the minutes used so far linearly to the end of the month (used × days in the month ÷ day of the month). When that projection is more than `AUTO_RELEASE_MINUTES_BUDGET_PCT` (default 85) percent of `AUTO_RELEASE_MINUTES_QUOTA` (default 400), the release waits until the tag is 28 days old.

The query needs `CI_MINUTES_TOKEN`, a masked CI/CD variable holding a personal access token with the `read_api` scope. GitLab's API cannot create one with that scope, so create it in the UI (Preferences → Access tokens). It reads the usage of the token owner's personal namespace. Without the token, or when the query fails, the run logs why and keeps the shorter period. `AUTO_RELEASE_MINUTES_BUDGET_PCT=0` turns the check off. GitHub and Forgejo runs never query anything, and security releases never wait.

The notes list the runtime inputs that changed, then the commits as usual, with the dependency updates under Dependencies. Security fixes do not wait for this: the `security` strategy still releases a `fix(security)` commit, a base image fix or a fresh rebuild at once.

## Fresh rebuilds

A Dockerfile that runs `apk add curl` or `apt-get install curl` without a version gets whatever the distribution ships on the day of the build. When the distribution fixes a CVE in one of those packages, nothing in the repository changes, so neither of the checks above sees it. A fresh rebuild covers that case. A run releases a patch, which builds the image from scratch (GitHub release builds skip the layer cache, GitLab's kaniko builds never use one), when all of these hold:

- The last release tag is at least `AUTO_RELEASE_REBUILD_DAYS` days old (default 7). A fix that is not out yet therefore costs at most one release per period, not one per run. `0` turns the check off.
- Trivy finds fixable HIGH/CRITICAL vulnerabilities, minus `.trivyignore`, in the distribution packages of `${AUTO_RELEASE_IMAGE}:<last version>`, the published image of the last release, that the final-stage base image named by the Dockerfile at the last tag does not have. Findings the base image has too need a base image update; findings in language packages (pip, npm, Go modules) are left out, since lock files and pinned versions make a rebuild produce the same ones.

The `security` strategy checks it on every push and `conventional` and `commits` on the scheduled run, which releases even when no `feat` or `fix` commit landed. The notes list each expected fix as CVE and package under "Security fixes in the image".

The image has to be matched to its Dockerfile: the check uses the one Dockerfile in `AUTO_RELEASE_DOCKERFILES` that exists at the last tag. With several, or without `AUTO_RELEASE_IMAGE`, it is skipped with a log line, and so it is when the base image cannot be resolved or either image cannot be scanned. A failed scan never fails the run.

The age comes from the tag. auto-release has pushed annotated tags since 0.4.0, which record when they were made; a lightweight tag counts from its commit's date, which can only be earlier, so the first fresh rebuild after an upgrade may come a few days early.

## Use it

Every repository releases on the same rhythm: Monday at 06:00 UTC with `conventional` (or `docker`), plus a run started by hand on the default branch for a release that cannot wait. Each push to the default branch runs `security`, so a CVE fix is released at once; any other push waits for Monday.

### Branches

`main` is always releasable: work happens on short-lived branches and reaches `main` through a pull or merge request, squash-merged. The squash commit's subject is the PR title, and auto-release reads that subject for the release-note line and the version bump, so a check (`mbologna/.github`'s `pr-title.yml` on GitHub, ci-templates' `conventional-title` on GitLab) requires PR titles to be Conventional Commits.

### GitHub

Call the reusable workflow in [`mbologna/.github`](https://github.com/mbologna/.github/blob/main/.github/workflows/auto-release.yml) from the repository's CI workflow:

```yaml
"on":
  push:
  schedule:
    - cron: "0 6 * * 1"
  workflow_dispatch:          # required: the tag build is started this way

jobs:
  auto-release:
    if: >-                    # Monday, a manual run, or a push (security only)
      github.event_name == 'schedule' ||
      ((github.event_name == 'workflow_dispatch' || github.event_name == 'push') &&
      github.ref == format('refs/heads/{0}', github.event.repository.default_branch))
    needs: [docker]
    permissions:
      contents: write         # push the tag, create the Release
      actions: write          # start this workflow on the new tag
    uses: mbologna/.github/.github/workflows/auto-release.yml@<sha> # main
    with:
      strategy: conventional  # or commits, docker; a push always runs security
      # dockerfiles: "Dockerfile tools/Dockerfile" (security strategy; default Dockerfile)
      # image: ghcr.io/mbologna/app                (docker strategy, registry login)
      # base_image_pattern: '^ARG UPSTREAM_'
      # dispatch_tag_build: false                  (no build runs on tags)
      # dispatch_workflow: publish.yml             (build the tag with another workflow)
      # dry_run: true                              (plan only, in the job summary)
```

### GitLab

Include the [`ci-templates`](https://gitlab.com/mbologna/ci-templates) component and set a masked `AUTO_RELEASE_TOKEN` CI/CD variable (a project or personal token with `api` and `write_repository`):

```yaml
include:
  - component: gitlab.com/mbologna/ci-templates/auto-release@7.0.0
    inputs:
      strategy: conventional  # or commits
      # maintenance_days: 7, runtime_paths: "...", minutes_budget_pct: 85
```

The release runs in scheduled pipelines on the default branch: add a pipeline schedule on `main` with cron `0 6 * * 1` (UTC), and use its "Run now" to release at once. A push to the default branch runs `security`. For the [CI minutes check](#on-gitlabs-ci-minutes), add a masked `CI_MINUTES_TOKEN` variable.

### Forgejo (Codeberg)

Run the image as the job container:

```yaml
jobs:
  auto-release:
    runs-on: docker
    container:
      image: ghcr.io/mbologna/auto-release:<version>
    steps:
      - uses: https://code.forgejo.org/actions/checkout@v4
        with:
          fetch-depth: 0
      - run: auto-release release
        env:
          AUTO_RELEASE_STRATEGY: commits
          AUTO_RELEASE_TOKEN: ${{ secrets.AUTO_RELEASE_TOKEN }}
          AUTO_RELEASE_DISPATCH_WORKFLOW: ci.yml
```

### Anywhere else

`auto-release plan` runs locally in any clone and prints what the next scheduled run would release.

## Configuration

| Variable | Meaning |
|---|---|
| `AUTO_RELEASE_STRATEGY` | `commits` (default), `conventional`, `docker` or `security` |
| `AUTO_RELEASE_DOCKERFILES` | Dockerfiles whose final base image the `security` strategy compares, separated by spaces or commas; default `Dockerfile`; missing ones are skipped |
| `AUTO_RELEASE_IMAGE` | image without a tag that the `docker` strategy compares and the fresh rebuild scans at the last version; GitLab defaults to `$CI_REGISTRY_IMAGE`. auto-release logs in to its registry with the forge's token |
| `AUTO_RELEASE_REBUILD_DAYS` | days after the last release when a [fresh rebuild](#fresh-rebuilds) may release; default 7, `0` turns it off |
| `AUTO_RELEASE_MAINTENANCE_DAYS` | days after the last release when a [maintenance release](#maintenance-releases) may release; default 7, `0` turns it off |
| `AUTO_RELEASE_MAINTENANCE_DAYS_OVER_BUDGET` | GitLab: days a maintenance release waits instead when the projected CI minutes are over budget; default 28 |
| `AUTO_RELEASE_MINUTES_BUDGET_PCT` | GitLab: the share of the monthly CI minutes, projected to the month's end, above which maintenance releases slow down; default 85, `0` turns the check off |
| `AUTO_RELEASE_MINUTES_QUOTA` | GitLab: the namespace's monthly CI minutes; default 400 |
| `CI_MINUTES_TOKEN` | GitLab: a `read_api` token that reads the CI minutes usage; without it the check is skipped |
| `AUTO_RELEASE_RUNTIME_PATHS` | the runtime inputs whose changes a maintenance release ships: shell patterns separated by spaces or commas; default `Dockerfile* uv.lock requirements*.txt pyproject.toml package.json package-lock.json go.mod go.sum composer.*` |
| `AUTO_RELEASE_BASE_IMAGE_PATTERN` | extended regular expression; matching `Dockerfile` lines go into the notes |
| `AUTO_RELEASE_TOKEN` | token that pushes the tag and creates the Release; GitHub and Forgejo fall back to `GITHUB_TOKEN` |
| `AUTO_RELEASE_DISPATCH` | `false` skips starting the tag build |
| `AUTO_RELEASE_DISPATCH_WORKFLOW` | workflow file to start on the tag; GitHub defaults to the calling workflow |
| `AUTO_RELEASE_CONFIG` | git-cliff config; defaults to `./cliff.toml`, then the bundled one |
| `AUTO_RELEASE_FORGE` | `github`, `gitlab`, `forgejo` or `none`; detected from the CI environment by default |
| `AUTO_RELEASE_DRY_RUN` | `true` makes `release` behave like `plan` |

The run needs the full history: `fetch-depth: 0` on GitHub and Forgejo, `GIT_DEPTH: 0` on GitLab. A shallow clone is refused.

## Tokens

GitHub does not start workflow runs for a tag pushed with `GITHUB_TOKEN`. `auto-release` therefore dispatches the calling workflow on the new tag, which is why the caller needs `actions: write` and a `workflow_dispatch` trigger. A tag pushed on GitLab with a project or personal token starts a tag pipeline by itself. The Forgejo example uses a personal token and names the workflow to dispatch, which covers both behaviours of its automatic token. Forgejo support is covered by the tests against a stubbed API and has not run on Codeberg.

A `release` run on a tag ref does nothing. The tag build that auto-release dispatches may be the same workflow that called it, and with the `docker` strategy that run would otherwise see the version image missing and tag again.

If creating the Release fails after the tag is pushed, the run still starts the tag build and then fails, so the missing Release shows up as a failed job.

## Development

`tests/auto-release.bats` builds throwaway repositories for each rule above. It stubs `curl`, `crane` and `trivy` and pushes tags to a local bare repository.

```sh
bats tests/                         # needs git, git-cliff, jq
docker build --target test .        # the same tests inside the release image
```

The image is `ghcr.io/mbologna/auto-release`, built from the [`Dockerfile`](Dockerfile) on Alpine's `git-cliff` and `crane` packages.
