# auto-release

`auto-release` tags the next semantic version of a repository and publishes a Release with
notes grouped by change type, on GitHub, GitLab and [Forgejo](https://forgejo.org/). The
release decision lives in one shell script and one container image, outside any forge's
release tooling, so the three forges follow the same rules. It derives the version from
[Conventional Commits](https://www.conventionalcommits.org/) and writes the notes with
[git-cliff](https://git-cliff.org/), as
[release-please](https://github.com/googleapis/release-please) does, but releases on a
schedule without a release pull request. The notes live only in the forge's Release:
nothing is committed back to the default branch, so the job needs no branch-protection
bypass.

## How a run decides

The last release is the highest `vX.Y.Z` tag, build metadata included (`v1.4.0+up2.15.3`);
pre-release tags such as `v1.3.0-rc1` do not count, and with no such tag the run does
nothing (push the first tag by hand). The strategy then decides whether a release is due:

| Strategy | Releases when |
|---|---|
| `commits` (default) | any commit landed since the tag, or a fresh rebuild is due |
| `conventional` | a `feat`, `fix`, `perf`, `revert` or breaking commit landed, a maintenance release is due, or a fresh rebuild is due |
| `security` | a `fix(security)` commit landed, a base image update fixes CVEs, or a fresh rebuild is due |

Any other strategy name fails the run, even before the first tag. A breaking change bumps
the major, even before 1.0.0, a `feat` the minor and anything else the patch.

Two variables cover repositories built on an upstream, following the
[versioning standard](https://github.com/mbologna/.github/blob/main/VERSIONING.md):

- `AUTO_RELEASE_METADATA_CMD` prints the pinned upstream version as build metadata:
  `up2.15.3` makes the next tag `v1.4.0+up2.15.3`. The version still follows the commits.
- `AUTO_RELEASE_UPSTREAM_CMD` prints the upstream version of a patched upstream image:
  tags become `v<upstream>+r<N>` (`v4.5.2+r1`, `v7d1914b5-ls396+r2`), N counting the
  releases of that upstream version, and the newest such tag is the last release.

Either way a changed pin releases under `commits` and `conventional`, whatever type the
commit that moved it had.
`auto-release release` pushes an annotated tag, creates the Release and, on GitHub and
Forgejo, starts the tag build. `auto-release plan` prints the version and notes and changes
nothing.

The base image and fresh rebuild checks scan images with
[Trivy](https://trivy.dev/). [docs/decisions.md](docs/decisions.md) covers each strategy,
the security check, fresh rebuilds, maintenance releases and failures;
[docs/release-notes.md](docs/release-notes.md) the notes;
[docs/ci-minutes.md](docs/ci-minutes.md) the GitLab CI minutes budget.

## Use it

The GitHub workflow and the GitLab component below are built for one rhythm: a scheduled
run on Monday at 06:00 UTC with `conventional`, a manual run for a release that cannot
wait, and `security` on pushes to the default branch, so a CVE fix is released at once and
any other change waits for Monday.

`main` is always releasable: work reaches it from short-lived branches through a pull or
merge request. auto-release reads the subjects of the commits that land for the notes and
the version bump, so they must be Conventional Commits. Pull and merge requests merge with
a merge commit on every forge, so the linted commits land as they are, and auto-release
skips the `Merge …` commit itself. Every commit is linted with
[commitlint-config](https://github.com/mbologna/commitlint-config) (`mbologna/.github`'s
`commits.yml` on GitHub, ci-templates' `commits` component on GitLab).

### GitHub

The reusable workflow
[`auto-release.yml`](https://github.com/mbologna/.github/blob/main/.github/workflows/auto-release.yml)
in `mbologna/.github` runs the image as a [GitHub Actions](https://docs.github.com/actions)
job container. A repository that builds its image with `mbologna/.github`'s
`docker-ci.yml` sets its `release_strategy` input, which calls `auto-release.yml` after
the build; others call `auto-release.yml` directly:

```yaml
"on":
  push:
  schedule:
    - cron: "0 6 * * 1"
  workflow_dispatch:          # required: the tag build is started this way

jobs:
  auto-release:
    needs: [build]
    permissions:
      contents: write         # push the tag, create the Release
      actions: write          # start this workflow on the new tag
    uses: mbologna/.github/.github/workflows/auto-release.yml@<sha> # main
    with:
      strategy: conventional  # or commits
      # optional: dockerfiles, image, base_image_pattern, dispatch_tag_build: false,
      # dispatch_workflow: publish.yml, dry_run: true
```

The workflow gates itself, so the caller needs no `if:`: it runs on the schedule, and on a
push or a manual run on the default branch, and skips pull requests, other branches and the
tag build. The schedule uses `strategy`, a push `security` and a manual run `commits`,
which releases whatever is unreleased. A caller still passing the removed `docker` strategy
gets `conventional` and a warning.

### GitLab

Include the `auto-release` component of
[`ci-templates`](https://gitlab.com/mbologna/ci-templates), a
[GitLab CI/CD component](https://docs.gitlab.com/ci/components/), and set a masked
`AUTO_RELEASE_TOKEN` CI/CD variable:

```yaml
include:
  - component: gitlab.com/mbologna/ci-templates/auto-release@8.1.0
    inputs:
      strategy: conventional  # or commits
      # dockerfiles: "...", maintenance_days: 7, runtime_paths: "...", minutes_budget_pct: 85,
      # security_paths: [...], image: "...", base_image_pattern: "...", dry_run: true
```

Add a pipeline schedule on `main` with cron `0 6 * * 1` (UTC); its "Run now" releases at
once with the same strategy. A push to the default branch runs `security` only when its
commit message contains `fix(security)` or it changes a file matching `security_paths`
(Dockerfiles and dependency manifests by default); any other push creates no auto-release
job.

### Forgejo (Codeberg)

Run the image as the job container of a
[Forgejo Actions](https://forgejo.org/docs/latest/user/actions/) workflow, for example on
[Codeberg](https://codeberg.org/):

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

`auto-release plan` runs in any clone and prints what the next run would release. The run
needs the full history (`fetch-depth: 0` on GitHub and Forgejo, `GIT_DEPTH: 0` on GitLab)
and refuses a shallow clone.

## Configuration

Every variable the script reads; "detected" and "set by CI" values come from the job.

| Variable | Default | Meaning |
|---|---|---|
| `AUTO_RELEASE_STRATEGY` | `commits` | `commits`, `conventional` or `security` |
| `AUTO_RELEASE_FORGE` | detected | `github`, `gitlab`, `forgejo` or `none`; with `none` only `plan` runs |
| `AUTO_RELEASE_TOKEN` | GitHub, Forgejo: `GITHUB_TOKEN` | pushes the tag and creates the Release; a due `release` fails without one |
| `AUTO_RELEASE_DRY_RUN` | unset | `true`, `1` or `yes` makes `release` behave like `plan` |
| `AUTO_RELEASE_DISPATCH` | `true` | any value other than `true`, `1` or `yes` skips starting the tag build (GitHub, Forgejo) |
| `AUTO_RELEASE_DISPATCH_WORKFLOW` | file named in `GITHUB_WORKFLOW_REF` | workflow file to start on the new tag; with neither, the dispatch is skipped |
| `AUTO_RELEASE_CONFIG` | `./cliff.toml`, else the bundled one | git-cliff config |
| `AUTO_RELEASE_METADATA_CMD` | unset | shell command, run in the checkout, whose one-line output is the tag's SemVer build metadata (`up2.15.3` → `v1.4.0+up2.15.3`); a change in it releases at least a patch |
| `AUTO_RELEASE_UPSTREAM_CMD` | unset | shell command whose one-line output is the upstream version of a patched upstream image; tags become `v<upstream>+r<N>`. Excludes `AUTO_RELEASE_METADATA_CMD` |
| `AUTO_RELEASE_IMAGE` | GitLab: `$CI_REGISTRY_IMAGE` | image without a tag: the fresh rebuild scans it, and the registry login is for its registry |
| `AUTO_RELEASE_DOCKERFILES` | `Dockerfile` | Dockerfiles whose final base image `security` compares, separated by spaces or commas; missing ones are skipped |
| `AUTO_RELEASE_SEVERITY` | `HIGH,CRITICAL` | Trivy severities the base image and fresh rebuild checks count |
| `AUTO_RELEASE_REBUILD_DAYS` | `7` | age of the last tag at which a fresh rebuild may release; `0` turns it off |
| `AUTO_RELEASE_MAINTENANCE_DAYS` | `7` | age of the last tag at which a maintenance release may release; `0` turns it off |
| `AUTO_RELEASE_RUNTIME_PATHS` | `Dockerfile* uv.lock requirements*.txt pyproject.toml package.json package-lock.json go.mod go.sum composer.*` | runtime inputs whose changes a maintenance release ships; shell patterns separated by spaces or commas |
| `AUTO_RELEASE_MAINTENANCE_DAYS_OVER_BUDGET` | `28` | GitLab: age a maintenance release waits for when CI minutes are over budget |
| `AUTO_RELEASE_MINUTES_BUDGET_PCT` | `85` | GitLab: projected share of the monthly CI minutes above which maintenance releases slow down; `0` turns the check off |
| `AUTO_RELEASE_MINUTES_QUOTA` | `400` | GitLab: the namespace's monthly CI minutes; `0` turns the check off |
| `CI_MINUTES_TOKEN` | unset | GitLab: `read_api` token that reads the CI minutes usage; without it the check is skipped |
| `AUTO_RELEASE_BASE_IMAGE_PATTERN` | unset | extended regular expression; matching lines of the root `Dockerfile` go into the notes |
| `AUTO_RELEASE_SHARE_DIR`, `AUTO_RELEASE_PUSH_URL`, `AUTO_RELEASE_TODAY` | `../share/auto-release` beside the script, forge push URL, today (UTC) | directory of the bundled `cliff.toml`; tests only: where tags are pushed and the `YYYY-MM-DD` date of the CI minutes projection |
| `FORGEJO_ACTIONS`, `GITEA_ACTIONS`, `GITHUB_ACTIONS`, `GITLAB_CI` | set by CI | forge detection, in that order (Forgejo's runner also sets `GITHUB_ACTIONS`) |
| `GITHUB_REPOSITORY`, `GITHUB_SERVER_URL`, `GITHUB_API_URL` | set by CI; `https://github.com`, `https://api.github.com` | GitHub, Forgejo: `owner/repo` (required), server for links and the push URL (required on Forgejo, whose API is `$GITHUB_SERVER_URL/api/v1`), GitHub API |
| `GITHUB_REF`, `CI_COMMIT_TAG` | set by CI | a tag ref makes `release` do nothing |
| `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY` | set by CI | receive `released=true\|false` and `tag`, and the notes |
| `CI_API_V4_URL`, `CI_PROJECT_ID`, `CI_PROJECT_PATH`, `CI_PROJECT_URL`, `CI_SERVER_FQDN` (or `CI_SERVER_HOST`), `CI_SERVER_PROTOCOL` | set by CI; protocol `https` | GitLab: API, push URL and links; all but the protocol required |
| `CI_REGISTRY`, `CI_JOB_TOKEN`, `CI_REGISTRY_IMAGE` | set by CI | GitLab: log in to the project's registry with the job token; default `AUTO_RELEASE_IMAGE` |
| `CI_API_GRAPHQL_URL`, `CI_SERVER_URL` | `$CI_SERVER_URL/api/graphql`, `https://gitlab.com` | GitLab: GraphQL endpoint of the CI minutes query |
| `HOME`, `GIT_CONFIG_GLOBAL`, `DOCKER_CONFIG` | environment | in CI the run trusts the checkout through a temporary `HOME` whose `.gitconfig` includes the real one, and keeps `~/.docker` as `DOCKER_CONFIG` |

## Tokens

- GitHub: the job's `GITHUB_TOKEN` with `contents: write` and `actions: write`. Its tags
  start no workflow run, so auto-release dispatches the tag build (`workflow_dispatch`).
- GitLab: `AUTO_RELEASE_TOKEN`, a project or personal token with `api` and
  `write_repository`; its tags start a tag pipeline. `CI_MINUTES_TOKEN` (optional) needs
  `read_api` and is created in the UI.
- Forgejo: a personal token in `AUTO_RELEASE_TOKEN`, with `AUTO_RELEASE_DISPATCH_WORKFLOW`
  set. This is tested against a stubbed API and has not run on Codeberg.

## Development

`tests/auto-release.bats` builds throwaway repositories for each rule, stubs `curl`,
[`crane`](https://github.com/google/go-containerregistry/tree/main/cmd/crane) and `trivy`,
and pushes tags to a local bare repository. Run `bats tests/` (needs
[Bats](https://bats-core.readthedocs.io/), git, git-cliff and [jq](https://jqlang.org/)) or
`docker build --target test .` for the same tests inside the image. CI also runs
[ShellCheck](https://www.shellcheck.net/) on `bin/auto-release`.

The image `ghcr.io/mbologna/auto-release` is built from the [`Dockerfile`](Dockerfile), on
[Alpine Linux](https://alpinelinux.org/) with crane, curl, git, git-cliff, jq and Trivy.
auto-release releases itself with `conventional` through `docker-ci.yml`'s
`release_strategy`, and only release tags publish the image.

