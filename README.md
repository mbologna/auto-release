# auto-release

`auto-release` tags the next semantic version of a repository and publishes a Release with grouped notes. No release pull request and no human step are involved. One shell script and one container image run on GitHub Actions, GitLab CI and Forgejo Actions, taking their inputs from the job environment.

It keeps what the earlier tools each did well. Like the old `auto-release` workflows, it releases on a schedule as soon as something changed. Like release-please, it derives the version from [Conventional Commits](https://www.conventionalcommits.org/) and writes notes grouped by change type. The notes live only in the forge's Release object. Nothing is committed back to the default branch, so the job needs no branch-protection bypass.

## How a run decides

1. The latest tag matching `vX.Y.Z` is the last release. Pre-release tags such as `v1.3.0-rc1` are ignored. With no such tag the run does nothing; push the first tag by hand.
2. The strategy decides whether a release is due:

   | Strategy | Releases when |
   |---|---|
   | `commits` (default) | any commit landed since the tag |
   | `conventional` | a `feat`, `fix`, `perf` or `revert` commit, or a breaking change, landed since the tag; `docs`, `chore`, `ci` and the rest alone do not release |
   | `docker` | the registry's `latest` image digest differs from the image tagged with the last version, or that version was never published |
   | `security` | a `fix(security)` commit landed (Renovate's CVE updates), or the base image of a Dockerfile changed and the new one no longer has fixable HIGH/CRITICAL [Trivy](https://trivy.dev/) findings that the old one has; the notes list those CVEs. See [The security strategy](#the-security-strategy) |

3. [git-cliff](https://git-cliff.org/) computes the bump. A breaking change (`type!:` or a `BREAKING CHANGE:` footer) bumps the major, even before 1.0.0. A `feat` bumps the minor, and anything else the patch. `docker` always bumps the patch.
4. `auto-release release` pushes the tag, creates the Release and, on GitHub and Forgejo, starts the tag build (see [Tokens](#tokens)). `auto-release plan` prints the version and notes and changes nothing.

## Release notes

The bundled [`share/auto-release/cliff.toml`](share/auto-release/cliff.toml) groups commits under Breaking changes, Features, Security (`*(security):`), Fixes, Performance, Reverts, Dependencies (`fix|chore|build(deps):`) and Other changes. Commits that do not follow Conventional Commits go under Other changes. Merge commits, `chore(release)` commits and Renovate digest and lock-file refreshes are left out. Each line links to its commit, and the notes end with a compare link.

The `security` strategy puts the CVEs that a base image update fixed under "Security fixes in the image" at the top. The `docker` strategy adds the new image digest there. When the base image pattern is set, the matching `Dockerfile` lines are added too.

A repository can provide its own `cliff.toml`, or point `AUTO_RELEASE_CONFIG` at one. The tag pattern is always passed on the command line.

## The security strategy

CI runs `security` on every push to the default branch, so it has to decide from the commit alone. Two things release at once:

- A `fix(security)` or `fix(security)!` commit since the last tag. This is the title Renovate gives its vulnerability updates. Other types with the same scope, such as `chore(security)` for a development-only dependency, wait for the next scheduled release.
- A base image update that fixes CVEs. For each Dockerfile in `AUTO_RELEASE_DOCKERFILES` (default `Dockerfile`), auto-release reads the base image of the final stage at the last tag and at `HEAD`. That is the image named by the last `FROM`, or by the stage it builds on when it is `FROM <stage>`. `${VAR}`, `${VAR:-default}` and `$VAR` take the defaults of the `ARG` lines before the first `FROM`, and `--platform` is ignored. When the reference changed, its tag or its digest, Trivy scans both images straight from their registries, with the same filter as everywhere else: vulnerabilities only, HIGH and CRITICAL, fixable ones, minus the checkout's `.trivyignore`. Findings in the old image that the new one does not have are the fixed CVEs. If there are any, the run releases and lists them.

Nothing is built for this check. A Dockerfile that is missing at `HEAD` is skipped silently. One added since the last tag, one that builds `FROM scratch`, one whose base depends on an `ARG` with no default, or one whose images cannot be scanned is skipped with a log line, and the run carries on.

Trivy reads registry credentials from the Docker config (`~/.docker/config.json` or `$DOCKER_CONFIG`) and its usual environment variables. Public base images on Docker Hub, `ghcr.io`, `lscr.io` or `registry.gitlab.com` need none. auto-release logs in to the project's own registry only, as before: on GitLab with the job token when `AUTO_RELEASE_IMAGE` (default `$CI_REGISTRY_IMAGE`) is there, on GitHub and Forgejo with the forge token when `AUTO_RELEASE_IMAGE` is on `ghcr.io` or the Forgejo host.

A repository with more than one image, or a Dockerfile outside the root, lists them all, separated by spaces or commas and relative to the repository root: `AUTO_RELEASE_DOCKERFILES: "Dockerfile tools/Dockerfile"`. The GitHub wrapper and the GitLab component take it as their `dockerfiles` input; on Forgejo, set it in the step's `env`. The base image tag or digest has to change in the Dockerfile for this check to see it. A floating tag such as `alpine:3` that moves upstream goes unnoticed, so pin digests and let Renovate move them.

Before 0.3.0 this check compared the image of the last version with the registry's `latest`, which meant building and pushing `latest` on every push. That comparison is gone: `AUTO_RELEASE_IMAGE` now only matters for the `docker` strategy and for the registry login.

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
  - component: gitlab.com/mbologna/ci-templates/auto-release@3.0.0
    inputs:
      strategy: commits       # or conventional, docker
```

The job runs only in scheduled pipelines on the default branch: add a pipeline schedule on `main` with cron `0 6 * * 1` (UTC), and use its "Run now" to release at once. The `docker` strategy reads `$CI_REGISTRY_IMAGE` with the job token.

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
| `AUTO_RELEASE_IMAGE` | image the `docker` strategy compares, without a tag; GitLab defaults to `$CI_REGISTRY_IMAGE`. auto-release logs in to its registry with the forge's token |
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
