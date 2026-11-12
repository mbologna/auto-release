#!/usr/bin/env bats
# Each test builds a throwaway repository, so the version rules are checked
# against real git history. curl and crane are stubbed: the stubs record what
# would have gone to the forge or registry, and tags go to a local bare repo.

bats_require_minimum_version 1.5.0

AUTO_RELEASE="${AUTO_RELEASE_BIN:-$BATS_TEST_DIRNAME/../bin/auto-release}"

setup() {
	cd "$BATS_TEST_TMPDIR"
	# Isolate from the developer's git config and hooks (commitlint, gitleaks).
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
	export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
	export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
	unset GITHUB_ACTIONS GITLAB_CI FORGEJO_ACTIONS GITEA_ACTIONS GITHUB_OUTPUT GITHUB_STEP_SUMMARY
	unset GITHUB_REF CI_COMMIT_TAG
	unset AUTO_RELEASE_STRATEGY AUTO_RELEASE_IMAGE AUTO_RELEASE_TOKEN AUTO_RELEASE_DRY_RUN
	unset AUTO_RELEASE_DOCKERFILES AUTO_RELEASE_REBUILD_DAYS

	mkdir -p stubs
	cat >stubs/curl <<-'EOF'
		#!/bin/sh
		# Records the URL and the JSON body; answers {} with success.
		url="" data=""
		while [ $# -gt 0 ]; do
			case $1 in
			--data) [ "$2" = @- ] && data=$(cat); shift ;;
			-X | -H) shift ;;
			http*) url=$1 ;;
			esac
			shift
		done
		printf '%s %s\n' "$url" "$data" >>"$STUB_LOG"
		echo '{}'
	EOF
	cat >stubs/crane <<-'EOF'
		#!/bin/sh
		# crane digest IMAGE:TAG -> the value of STUB_DIGEST_<TAG>, else not found.
		[ "$1" = digest ] || exit 0
		tag=$(printf '%s' "${2##*:}" | tr . _)
		eval "d=\${STUB_DIGEST_$tag:-}"
		[ -n "$d" ] || { echo "MANIFEST_UNKNOWN" >&2; exit 1; }
		echo "$d"
	EOF
	cat >stubs/trivy <<-'EOF'
		#!/bin/sh
		# trivy image ... IMAGE:TAG -> JSON with STUB_VULNS_<TAG> ("CVE pkg;CVE pkg"),
		# or a scan failure when STUB_VULNS_<TAG> is unset. <TAG> is the part
		# after the last colon (the digest for IMAGE:TAG@sha256:...), other
		# characters than letters and digits turned into _. A finding is in an
		# OS package unless a third word names its class ("CVE pkg lang-pkgs").
		# Logs each image.
		for last; do :; done
		printf '%s\n' "$last" >>"$TRIVY_LOG"
		tag=$(printf '%s' "${last##*:}" | tr -c 'A-Za-z0-9' _)
		eval "set -- \${STUB_VULNS_$tag+x}"
		[ -n "${1:-}" ] || { echo "image not found" >&2; exit 1; }
		eval "v=\$STUB_VULNS_$tag"
		printf '%s' "$v" | tr ';' '\n' | jq -R -s -c '{Results: [split("\n")[] | select(length > 0) |
			split(" ") | {Class: (.[2] // "os-pkgs"), VulnerabilityID: .[0], PkgName: .[1]}] |
			group_by(.Class) | map({Class: .[0].Class, Vulnerabilities: map(del(.Class))})}'
	EOF
	chmod +x stubs/*
	export PATH="$BATS_TEST_TMPDIR/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
	export TRIVY_LOG="$BATS_TEST_TMPDIR/trivy.log"
	: >"$STUB_LOG"
	: >"$TRIVY_LOG"

	git init -q --bare remote.git
	git init -q -b main repo
	cd repo
	git remote add origin "$BATS_TEST_TMPDIR/remote.git"
	commit "chore: initial commit"
}

commit() { git commit -q --allow-empty -m "$1"; }

# Writes a Dockerfile (default ./Dockerfile) from printf-style lines and stages it.
dockerfile() {
	path=${DOCKERFILE:-Dockerfile}
	mkdir -p "$(dirname "$path")"
	printf '%s\n' "$@" >"$path"
	git add "$path"
}

# Tags HEAD with an annotated tag, as auto-release does, made DAYS (default 8)
# days ago.
old_tag() {
	GIT_COMMITTER_DATE="$(($(date +%s) - ${2:-8} * 86400)) +0000" git tag -a -m "$1" "$1"
}

# Runs plan and leaves the proposed tag (or "none") in $next.
next_tag() {
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	next=$(printf '%s\n' "$output" | sed -n 's/^## //p' | head -n 1)
	next=${next:-none}
}

@test "fix bumps the patch" {
	git tag v1.2.3
	commit "fix: correct the retry count"
	next_tag
	[ "$next" = v1.2.4 ]
}

@test "feat bumps the minor" {
	git tag v1.2.3
	commit "fix: a"
	commit "feat(api): add an endpoint"
	next_tag
	[ "$next" = v1.3.0 ]
}

@test "type! bumps the major" {
	git tag v1.2.3
	commit "refactor(core)!: drop the old config"
	next_tag
	[ "$next" = v2.0.0 ]
}

@test "a BREAKING CHANGE footer bumps the major" {
	git tag v1.2.3
	commit "$(printf 'fix: rename the flag\n\nBREAKING CHANGE: --old is gone')"
	next_tag
	[ "$next" = v2.0.0 ]
}

@test "a breaking change before 1.0.0 goes to 1.0.0" {
	git tag v0.4.1
	commit "feat!: new storage format"
	next_tag
	[ "$next" = v1.0.0 ]
}

@test "feat before 1.0.0 bumps the minor" {
	git tag v0.4.1
	commit "feat: a"
	next_tag
	[ "$next" = v0.5.0 ]
}

@test "commits: any commit releases a patch, even chore or unconventional" {
	git tag v1.2.3
	commit "chore(deps): update x"
	commit "tidy things up"
	next_tag
	[ "$next" = v1.2.4 ]
}

@test "commits: only skipped commits still release a patch" {
	git tag v1.2.3
	git checkout -q -b topic
	commit "chore(release): v9"
	git checkout -q main
	git merge -q --no-ff -m "Merge branch 'topic'" topic
	next_tag
	[ "$next" = v1.2.4 ]
}

@test "no commits since the tag: no release" {
	git tag v1.2.3
	next_tag
	[ "$next" = none ]
}

@test "no tag yet: skip and say how to bootstrap" {
	commit "feat: a"
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"push an initial tag"* ]]
	[ -z "$output" ]
}

@test "pre-release and non-semver tags are not the latest release" {
	git tag v1.2.3
	commit "feat: a"
	git tag v1.3.0-rc1
	git tag latest
	commit "fix: b"
	next_tag
	[ "$next" = v1.3.0 ]
}

@test "conventional: docs, chore and ci alone do not release" {
	export AUTO_RELEASE_STRATEGY=conventional
	git tag v1.2.3
	commit "docs: a"
	commit "chore(deps): b"
	commit "ci: c"
	next_tag
	[ "$next" = none ]
}

@test "conventional: a fix releases a patch" {
	export AUTO_RELEASE_STRATEGY=conventional
	git tag v1.2.3
	commit "docs: a"
	commit "fix(deps): update the provider"
	next_tag
	[ "$next" = v1.2.4 ]
}

@test "conventional: a breaking chore releases a major" {
	export AUTO_RELEASE_STRATEGY=conventional
	git tag v1.2.3
	commit "chore!: require terraform 1.10"
	next_tag
	[ "$next" = v2.0.0 ]
}

@test "docker: a new digest releases a patch, even after a feat" {
	export AUTO_RELEASE_STRATEGY=docker AUTO_RELEASE_IMAGE=docker.io/example/app
	export STUB_DIGEST_1_2_3=sha256:old STUB_DIGEST_latest=sha256:new
	git tag v1.2.3
	commit "feat: a"
	next_tag
	[ "$next" = v1.2.4 ]
	[[ "$output" == *'Image digest changed: `sha256:new`'* ]]
}

@test "docker: an unpublished version tag releases" {
	export AUTO_RELEASE_STRATEGY=docker AUTO_RELEASE_IMAGE=docker.io/example/app
	export STUB_DIGEST_latest=sha256:new
	git tag v1.2.3
	next_tag
	[ "$next" = v1.2.4 ]
}

@test "docker: the same digest does not release" {
	export AUTO_RELEASE_STRATEGY=docker AUTO_RELEASE_IMAGE=docker.io/example/app
	export STUB_DIGEST_1_2_3=sha256:same STUB_DIGEST_latest=sha256:same
	git tag v1.2.3
	commit "fix: a"
	next_tag
	[ "$next" = none ]
}

@test "notes: grouped by type, breaking changes first, merges and releases skipped" {
	git tag v1.2.3
	commit "feat(api): add the ETA endpoint"
	commit "fix: name the limit"
	commit "fix(security): update filelock to 4.2.1"
	commit "chore(deps): update uv to 0.13.0"
	commit "docs: document the CLI"
	commit "$(printf 'refactor(core)!: drop v1 config\n\nBREAKING CHANGE: the v1 config is no longer read')"
	commit "chore(release): v9"
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	notes=$(printf '%s\n' "$output" | sed -E 's/ \([0-9a-f]{7}\)$//')
	expected=$(
		cat <<-'EOF'
			## v2.0.0

			### ⚠ Breaking changes

			- **core:** the v1 config is no longer read

			### Features

			- **api:** add the ETA endpoint

			### Security

			- update filelock to 4.2.1

			### Fixes

			- name the limit

			### Dependencies

			- update uv to 0.13.0

			### Other changes

			- **core:** drop v1 config
			- document the CLI
		EOF
	)
	[ "$notes" = "$expected" ]
}

@test "notes: Renovate digest and lock file refreshes are left out" {
	git tag v1.2.3
	commit "chore(deps): update action/.github to cebe9d2 (digest) [automerge] (#191)"
	commit "chore(deps): maintain terraform/ (lockFileMaintenance) [automerge] (#180)"
	commit "chore(deps): maintain lock files (#55)"
	commit "chore(deps): update python from 3.14.7 to 3.14.8 (patch) (#7)"
	next_tag
	[ "$next" = v1.2.4 ]
	[[ "$output" == *"update python from 3.14.7 to 3.14.8"* ]]
	[[ "$output" != *"(digest)"* ]]
	[[ "$output" != *"lockFileMaintenance"* ]]
	[[ "$output" != *"maintain lock files"* ]]
}

@test "notes: the base image lines are included" {
	export AUTO_RELEASE_BASE_IMAGE_PATTERN='^ARG UPSTREAM_'
	printf 'ARG UPSTREAM_VERSION=4.5.2\nFROM alpine\n' >Dockerfile
	git tag v1.2.3
	commit "fix: a"
	next_tag
	[[ "$output" == *'ARG UPSTREAM_VERSION=4.5.2'* ]]
}

@test "a caller's cliff.toml replaces the bundled one" {
	cat >cliff.toml <<-'EOF'
		[changelog]
		body = "custom notes"
		[git]
		conventional_commits = true
	EOF
	git tag v1.2.3
	commit "fix: a"
	next_tag
	[[ "$output" == *"custom notes"* ]]
}

@test "shallow clones are refused" {
	git tag v1.2.3
	commit "fix: a"
	commit "fix: b"
	git push -q origin main --tags
	cd ..
	git clone -q -b main --depth 1 "file://$BATS_TEST_TMPDIR/remote.git" shallow
	cd shallow
	run "$AUTO_RELEASE" plan
	[ "$status" -ne 0 ]
	[[ "$output" == *"shallow clone"* ]]
}

@test "release without a forge is refused" {
	git tag v1.2.3
	commit "fix: a"
	run "$AUTO_RELEASE" release
	[ "$status" -ne 0 ]
	[[ "$output" == *"no forge detected"* ]]
}

@test "AUTO_RELEASE_DRY_RUN turns release into plan" {
	export GITHUB_ACTIONS=true GITHUB_REPOSITORY=example/app GITHUB_TOKEN=secret
	export AUTO_RELEASE_DRY_RUN=true AUTO_RELEASE_PUSH_URL="$BATS_TEST_TMPDIR/remote.git"
	git tag v1.2.3
	commit "fix: a"
	run --separate-stderr "$AUTO_RELEASE" release
	[ "$status" -eq 0 ]
	[ -z "$(git ls-remote --tags "$BATS_TEST_TMPDIR/remote.git" v1.2.4)" ]
	[ ! -s "$STUB_LOG" ]
}

@test "github: pushes the tag, creates the Release, dispatches the caller" {
	export GITHUB_ACTIONS=true GITHUB_REPOSITORY=example/app GITHUB_TOKEN=secret
	export GITHUB_WORKFLOW_REF="example/app/.github/workflows/ci.yml@refs/heads/main"
	export AUTO_RELEASE_PUSH_URL="$BATS_TEST_TMPDIR/remote.git"
	export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
	git tag v1.2.3
	commit "feat: a"
	run --separate-stderr "$AUTO_RELEASE" release
	[ "$status" -eq 0 ]
	[ -n "$(git ls-remote --tags "$BATS_TEST_TMPDIR/remote.git" v1.3.0)" ]
	grep -q '^https://api.github.com/repos/example/app/releases {"tag_name":"v1.3.0"' "$STUB_LOG"
	grep -q '"body":"### Features' "$STUB_LOG"
	grep -q '^https://api.github.com/repos/example/app/actions/workflows/ci.yml/dispatches {"ref":"v1.3.0"}' "$STUB_LOG"
	grep -qx 'released=true' "$GITHUB_OUTPUT"
	grep -qx 'tag=v1.3.0' "$GITHUB_OUTPUT"
	grep -q '^## Released v1.3.0' "$GITHUB_STEP_SUMMARY"
}

@test "github: AUTO_RELEASE_DISPATCH=false skips the tag build" {
	export GITHUB_ACTIONS=true GITHUB_REPOSITORY=example/app GITHUB_TOKEN=secret
	export GITHUB_WORKFLOW_REF="example/app/.github/workflows/release.yml@refs/heads/main"
	export AUTO_RELEASE_PUSH_URL="$BATS_TEST_TMPDIR/remote.git" AUTO_RELEASE_DISPATCH=false
	git tag v1.2.3
	commit "fix: a"
	run --separate-stderr "$AUTO_RELEASE" release
	[ "$status" -eq 0 ]
	! grep -q dispatches "$STUB_LOG"
}

@test "gitlab: creates the Release with the project token, no dispatch" {
	export GITLAB_CI=true CI_API_V4_URL=https://gitlab.example.com/api/v4 CI_PROJECT_ID=42
	export CI_SERVER_HOST=gitlab.example.com CI_PROJECT_PATH=example/app
	export CI_PROJECT_URL=https://gitlab.example.com/example/app AUTO_RELEASE_TOKEN=secret
	export AUTO_RELEASE_PUSH_URL="$BATS_TEST_TMPDIR/remote.git"
	git tag v1.2.3
	commit "fix: a"
	run --separate-stderr "$AUTO_RELEASE" release
	[ "$status" -eq 0 ]
	grep -q '^https://gitlab.example.com/api/v4/projects/42/releases {"tag_name":"v1.2.4","name":"v1.2.4","description":"### Fixes' "$STUB_LOG"
	grep -q 'https://gitlab.example.com/example/app/-/commit/' "$STUB_LOG"
	! grep -q dispatches "$STUB_LOG"
}

@test "gitlab: no token fails before tagging" {
	export GITLAB_CI=true CI_API_V4_URL=https://gitlab.example.com/api/v4 CI_PROJECT_ID=42
	export CI_SERVER_HOST=gitlab.example.com CI_PROJECT_PATH=example/app
	export CI_PROJECT_URL=https://gitlab.example.com/example/app
	export AUTO_RELEASE_PUSH_URL="$BATS_TEST_TMPDIR/remote.git"
	git tag v1.2.3
	commit "fix: a"
	run "$AUTO_RELEASE" release
	[ "$status" -ne 0 ]
	[[ "$output" == *"no token"* ]]
	[ -z "$(git tag --list v1.2.4)" ]
}

@test "forgejo: detected before github, uses the v1 API" {
	export GITHUB_ACTIONS=true FORGEJO_ACTIONS=true GITHUB_SERVER_URL=https://codeberg.org
	export GITHUB_REPOSITORY=example/app GITHUB_TOKEN=secret
	export AUTO_RELEASE_PUSH_URL="$BATS_TEST_TMPDIR/remote.git" AUTO_RELEASE_DISPATCH_WORKFLOW=ci.yml
	git tag v1.2.3
	commit "fix: a"
	run --separate-stderr "$AUTO_RELEASE" release
	[ "$status" -eq 0 ]
	grep -q '^https://codeberg.org/api/v1/repos/example/app/releases ' "$STUB_LOG"
	grep -q '^https://codeberg.org/api/v1/repos/example/app/actions/workflows/ci.yml/dispatches ' "$STUB_LOG"
}

@test "a failed Release still dispatches the build, then fails the job" {
	export GITHUB_ACTIONS=true GITHUB_REPOSITORY=example/app GITHUB_TOKEN=secret
	export GITHUB_WORKFLOW_REF="example/app/.github/workflows/ci.yml@refs/heads/main"
	export AUTO_RELEASE_PUSH_URL="$BATS_TEST_TMPDIR/remote.git"
	cat >"$BATS_TEST_TMPDIR/stubs/curl" <<-'EOF'
		#!/bin/sh
		for a; do case $a in *releases) echo '{"message":"Resource not accessible"}'; exit 22 ;; *dispatches) echo dispatched >>"$STUB_LOG" ;; esac; done
		cat >/dev/null
	EOF
	git tag v1.2.3
	commit "fix: a"
	run "$AUTO_RELEASE" release
	[ "$status" -ne 0 ]
	[[ "$output" == *"creating the Release for v1.2.4 failed"* ]]
	grep -qx dispatched "$STUB_LOG"
}

@test "a release run on a tag ref does nothing, so a dispatched tag build cannot loop" {
	export GITHUB_ACTIONS=true GITHUB_REPOSITORY=example/app GITHUB_TOKEN=secret
	export GITHUB_REF=refs/tags/v1.2.3 AUTO_RELEASE_PUSH_URL="$BATS_TEST_TMPDIR/remote.git"
	export AUTO_RELEASE_STRATEGY=docker AUTO_RELEASE_IMAGE=docker.io/example/app STUB_DIGEST_latest=sha256:new
	git tag v1.2.3
	run "$AUTO_RELEASE" release
	[ "$status" -eq 0 ]
	[[ "$output" == *"Running on tag v1.2.3"* ]]
	[ -z "$(git ls-remote --tags "$BATS_TEST_TMPDIR/remote.git")" ]
	[ ! -s "$STUB_LOG" ]
}

@test "gitlab: a tag pipeline does not release" {
	export GITLAB_CI=true CI_COMMIT_TAG=v1.2.3 AUTO_RELEASE_TOKEN=secret
	git tag v1.2.3
	commit "fix: a"
	run "$AUTO_RELEASE" release
	[ "$status" -eq 0 ]
	[[ "$output" == *"Running on tag v1.2.3"* ]]
}

@test "security: a Renovate fix(security) update releases at once" {
	export AUTO_RELEASE_STRATEGY=security
	git tag v1.2.3
	commit "chore(deps): update x"
	commit "fix(security): update filelock to 4.2.1"
	next_tag
	[ "$next" = v1.2.4 ]
	[[ "$output" == *"### Security"* ]]
}

@test "security: chores and features alone wait for Monday" {
	export AUTO_RELEASE_STRATEGY=security
	git tag v1.2.3
	commit "chore(deps): update python from 3.14.7 to 3.14.8"
	commit "feat: a"
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[[ "$stderr" == *"No security fix since v1.2.3"* ]]
}

@test "security: chore(security) and other types do not release" {
	export AUTO_RELEASE_STRATEGY=security
	git tag v1.2.3
	commit "chore(security): update a dev-only linter"
	commit "build(security): bump the test runner"
	next_tag
	[ "$next" = none ]
}

@test "security: a base image update that drops CVEs releases, listing them" {
	export AUTO_RELEASE_STRATEGY=security
	export STUB_VULNS_3_24_3="CVE-2026-1 openssl;CVE-2026-2 zlib;CVE-2026-3 busybox"
	export STUB_VULNS_3_24_4="CVE-2026-3 busybox"
	dockerfile 'FROM alpine:3.24.3' 'RUN apk add --no-cache curl'
	commit "feat: add a Dockerfile"
	git tag v1.2.3
	dockerfile 'FROM alpine:3.24.4' 'RUN apk add --no-cache curl'
	commit "chore(deps): update alpine to 3.24.4"
	next_tag
	[ "$next" = v1.2.4 ]
	[[ "$output" == *"### Security fixes in the image"* ]]
	[[ "$output" == *'- CVE-2026-1 in `openssl`'* ]]
	[[ "$output" == *'- CVE-2026-2 in `zlib`'* ]]
	[[ "$output" != *"CVE-2026-3"* ]]
	grep -qx alpine:3.24.3 "$TRIVY_LOG"
	grep -qx alpine:3.24.4 "$TRIVY_LOG"
}

@test "security: global ARG defaults resolve in the base image reference" {
	export AUTO_RELEASE_STRATEGY=security
	export STUB_VULNS_abc_ls12="CVE-2026-1 openssl" STUB_VULNS_abc_ls13=""
	dockerfile '# syntax=docker/dockerfile:1' 'ARG REGISTRY="docker.io"' 'ARG BASE_TAG=abc-ls12' \
		'FROM ${REGISTRY}/example/img:${BASE_TAG}' 'ARG BASE_TAG=ignored'
	commit "feat: add a Dockerfile"
	git tag v1.2.3
	dockerfile '# syntax=docker/dockerfile:1' 'ARG REGISTRY="docker.io"' 'ARG BASE_TAG=abc-ls13' \
		'FROM $REGISTRY/example/img:${BASE_TAG:-latest}' 'ARG BASE_TAG=ignored'
	commit "chore(deps): update example/img to abc-ls13"
	next_tag
	[ "$next" = v1.2.4 ]
	[[ "$output" == *'- CVE-2026-1 in `openssl`'* ]]
	grep -qx docker.io/example/img:abc-ls12 "$TRIVY_LOG"
	grep -qx docker.io/example/img:abc-ls13 "$TRIVY_LOG"
}

@test "security: the final stage is followed to the stage it builds on" {
	export AUTO_RELEASE_STRATEGY=security
	export STUB_VULNS_aaa="CVE-2026-1 openssl" STUB_VULNS_bbb=""
	dockerfile 'FROM --platform=$BUILDPLATFORM golang:1.25 AS build' \
		'FROM nginx:1.29@sha256:aaa AS Base' 'RUN true' \
		'FROM base' 'COPY --from=build \' '    /out /usr/share/nginx/html'
	commit "feat: add a Dockerfile"
	git tag v1.2.3
	dockerfile 'FROM --platform=$BUILDPLATFORM golang:1.26 AS build' \
		'FROM nginx:1.29@sha256:bbb AS Base' 'RUN true' \
		'FROM base' 'COPY --from=build \' '    /out /usr/share/nginx/html'
	commit "chore(deps): update nginx digest"
	next_tag
	[ "$next" = v1.2.4 ]
	[ "$(cat "$TRIVY_LOG")" = "$(printf 'nginx:1.29@sha256:aaa\nnginx:1.29@sha256:bbb')" ]
}

@test "security: an unchanged base image is not scanned and does not release" {
	export AUTO_RELEASE_STRATEGY=security AUTO_RELEASE_IMAGE=ghcr.io/example/app
	export STUB_VULNS_1_2_3="CVE-2026-1 openssl" STUB_VULNS_latest=""
	dockerfile 'FROM python:3.14-slim' 'RUN pip install requests'
	commit "feat: add a Dockerfile"
	git tag v1.2.3
	dockerfile 'FROM python:3.14-slim' 'RUN pip install requests httpx'
	commit "feat: add httpx"
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[[ "$stderr" == *"Base image of Dockerfile unchanged since v1.2.3: python:3.14-slim"* ]]
	[ ! -s "$TRIVY_LOG" ]
}

@test "security: a base image update without fixed CVEs does not release" {
	export AUTO_RELEASE_STRATEGY=security
	export STUB_VULNS_3_24_3="CVE-2026-3 busybox"
	export STUB_VULNS_3_24_4="CVE-2026-3 busybox;CVE-2026-9 curl"
	dockerfile 'FROM alpine:3.24.3'
	commit "feat: add a Dockerfile"
	git tag v1.2.3
	dockerfile 'FROM alpine:3.24.4'
	commit "chore(deps): update alpine to 3.24.4"
	next_tag
	[ "$next" = none ]
}

@test "security: listed Dockerfiles that do not exist are skipped" {
	export AUTO_RELEASE_STRATEGY=security AUTO_RELEASE_DOCKERFILES="Dockerfile, ./tools/Dockerfile missing/Dockerfile"
	export STUB_VULNS_1_2="CVE-2026-1 openssl;CVE-2026-2 zlib" STUB_VULNS_1_3="CVE-2026-2 zlib"
	DOCKERFILE=tools/Dockerfile dockerfile 'FROM syncthing/syncthing:1.2'
	commit "feat: add the tools image"
	git tag v1.2.3
	DOCKERFILE=tools/Dockerfile dockerfile 'FROM syncthing/syncthing:1.3'
	commit "chore(deps): update syncthing to 1.3"
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[[ "$output" == "## v1.2.4"* ]]
	[[ "$output" == *'- CVE-2026-1 in `openssl`'* ]]
	[[ "$output" != *"CVE-2026-2"* ]]
	[[ "$stderr" != *"missing/Dockerfile"* ]]
}

@test "security: a Dockerfile added since the last version is not compared" {
	export AUTO_RELEASE_STRATEGY=security
	git tag v1.2.3
	dockerfile 'FROM alpine:3.24.4'
	commit "feat: add a Dockerfile"
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[[ "$stderr" == *"Dockerfile is new since v1.2.3"* ]]
}

@test "security: an unresolvable base image is skipped with a warning" {
	export AUTO_RELEASE_STRATEGY=security
	dockerfile 'ARG BASE' 'FROM ${BASE}'
	commit "feat: add a Dockerfile"
	git tag v1.2.3
	dockerfile 'ARG BASE' 'FROM ${BASE}' 'RUN true'
	commit "fix(security): update requests to 2.33.0"
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"cannot resolve the base image of Dockerfile"* ]]
	[[ "$output" == "## v1.2.4"* ]]
}

@test "security: a base image that cannot be scanned skips only that check" {
	export AUTO_RELEASE_STRATEGY=security
	export STUB_VULNS_3_24_4=""
	dockerfile 'FROM alpine:3.24.3'
	commit "feat: add a Dockerfile"
	git tag v1.2.3
	dockerfile 'FROM alpine:3.24.4'
	commit "fix(security): update requests to 2.33.0"
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"cannot scan alpine:3.24.3"* ]]
	[[ "$output" == "## v1.2.4"* ]]
	[[ "$output" != *"Security fixes in the image"* ]]
}

@test "security: a breaking fix(security) still bumps by the commit rules" {
	export AUTO_RELEASE_STRATEGY=security
	git tag v1.2.3
	commit "fix(security)!: drop TLS 1.1"
	next_tag
	[ "$next" = v2.0.0 ]
}

@test "rebuild: a finding only in the packages the image adds releases a patch, listing it" {
	export AUTO_RELEASE_STRATEGY=security AUTO_RELEASE_IMAGE=ghcr.io/example/app
	export STUB_VULNS_1_2_3="CVE-2026-1 openssl;CVE-2026-5 curl;CVE-2026-6 nghttp2"
	export STUB_VULNS_3_24_3="CVE-2026-1 openssl"
	dockerfile 'FROM alpine:3.24.3' 'RUN apk add --no-cache curl'
	commit "feat: add a Dockerfile"
	old_tag v1.2.3
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[[ "$output" == "## v1.2.4"* ]]
	[[ "$output" == *"### Security fixes in the image"* ]]
	[[ "$output" == *"expected to fix these findings of v1.2.3"* ]]
	[[ "$output" == *'- CVE-2026-5 in `curl`'* ]]
	[[ "$output" == *'- CVE-2026-6 in `nghttp2`'* ]]
	[[ "$output" != *"CVE-2026-1"* ]]
	[[ "$output" == *"No commits since v1.2.3."* ]]
	grep -qx ghcr.io/example/app:1.2.3 "$TRIVY_LOG"
	grep -qx alpine:3.24.3 "$TRIVY_LOG"
}

@test "rebuild: findings the base image has too do not release" {
	export AUTO_RELEASE_STRATEGY=security AUTO_RELEASE_IMAGE=ghcr.io/example/app
	export STUB_VULNS_1_2_3="CVE-2026-1 openssl" STUB_VULNS_3_24_3="CVE-2026-1 openssl;CVE-2026-2 zlib"
	dockerfile 'FROM alpine:3.24.3' 'RUN apk add --no-cache curl'
	commit "feat: add a Dockerfile"
	old_tag v1.2.3
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[[ "$stderr" == *"Fresh rebuild check: none in the packages Dockerfile installs"* ]]
}

@test "rebuild: language packages do not count, a rebuild keeps their versions" {
	export AUTO_RELEASE_STRATEGY=security AUTO_RELEASE_IMAGE=ghcr.io/example/app
	export STUB_VULNS_1_2_3="CVE-2026-7 requests lang-pkgs" STUB_VULNS_3_14_slim=""
	dockerfile 'FROM python:3.14-slim' 'RUN pip install requests==2.0.0'
	commit "feat: add a Dockerfile"
	old_tag v1.2.3
	next_tag
	[ "$next" = none ]
}

@test "rebuild: a release younger than AUTO_RELEASE_REBUILD_DAYS is not scanned" {
	export AUTO_RELEASE_STRATEGY=security AUTO_RELEASE_IMAGE=ghcr.io/example/app
	export STUB_VULNS_1_2_3="CVE-2026-5 curl" STUB_VULNS_3_24_3=""
	dockerfile 'FROM alpine:3.24.3' 'RUN apk add --no-cache curl'
	commit "feat: add a Dockerfile"
	old_tag v1.2.3 6
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[[ "$stderr" == *"v1.2.3 is 6 days old, under AUTO_RELEASE_REBUILD_DAYS=7"* ]]
	[ ! -s "$TRIVY_LOG" ]
}

@test "rebuild: AUTO_RELEASE_REBUILD_DAYS sets the age, 0 disables the check" {
	export AUTO_RELEASE_STRATEGY=security AUTO_RELEASE_IMAGE=ghcr.io/example/app
	export STUB_VULNS_1_2_3="CVE-2026-5 curl" STUB_VULNS_3_24_3=""
	dockerfile 'FROM alpine:3.24.3' 'RUN apk add --no-cache curl'
	commit "feat: add a Dockerfile"
	old_tag v1.2.3 6
	AUTO_RELEASE_REBUILD_DAYS=5 next_tag
	[ "$next" = v1.2.4 ]
	: >"$TRIVY_LOG"
	AUTO_RELEASE_REBUILD_DAYS=0 next_tag
	[ "$next" = none ]
	[ ! -s "$TRIVY_LOG" ]
	AUTO_RELEASE_REBUILD_DAYS=weekly run "$AUTO_RELEASE" plan
	[ "$status" -ne 0 ]
	[[ "$output" == *"AUTO_RELEASE_REBUILD_DAYS must be a whole number"* ]]
}

@test "rebuild: an image that cannot be scanned skips the check" {
	export AUTO_RELEASE_STRATEGY=security AUTO_RELEASE_IMAGE=ghcr.io/example/app
	export STUB_VULNS_3_24_3=""
	dockerfile 'FROM alpine:3.24.3' 'RUN apk add --no-cache curl'
	commit "feat: add a Dockerfile"
	old_tag v1.2.3
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[[ "$stderr" == *"cannot scan ghcr.io/example/app:1.2.3; skipping the fresh rebuild check"* ]]
	unset STUB_VULNS_3_24_3
	export STUB_VULNS_1_2_3="CVE-2026-5 curl"
	commit "fix(security): update requests to 2.33.0"
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"cannot scan alpine:3.24.3; skipping the fresh rebuild check"* ]]
	[[ "$output" == "## v1.2.4"* ]]
	[[ "$output" != *"Security fixes in the image"* ]]
}

@test "rebuild: several Dockerfiles with one image are skipped" {
	export AUTO_RELEASE_STRATEGY=security AUTO_RELEASE_IMAGE=ghcr.io/example/app
	export AUTO_RELEASE_DOCKERFILES="Dockerfile-master Dockerfile-minion"
	export STUB_VULNS_1_2_3="CVE-2026-5 curl" STUB_VULNS_3_24_3=""
	DOCKERFILE=Dockerfile-master dockerfile 'FROM alpine:3.24.3'
	DOCKERFILE=Dockerfile-minion dockerfile 'FROM alpine:3.24.3'
	commit "feat: add the images"
	old_tag v1.2.3
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[[ "$stderr" == *"several Dockerfiles but one AUTO_RELEASE_IMAGE"* ]]
	[ ! -s "$TRIVY_LOG" ]
}

@test "rebuild: the scheduled conventional run releases without feat or fix commits" {
	export AUTO_RELEASE_STRATEGY=conventional AUTO_RELEASE_IMAGE=registry.gitlab.com/example/app
	export STUB_VULNS_1_2_3="CVE-2026-5 curl" STUB_VULNS_aaa=""
	dockerfile 'FROM debian:13-slim@sha256:aaa' 'RUN apt-get install -y curl'
	# A lightweight tag, as before 0.4.0, counts from its commit's date.
	GIT_COMMITTER_DATE="$(($(date +%s) - 30 * 86400)) +0000" commit "feat: add a Dockerfile"
	git tag v1.2.3
	commit "chore(deps): update a dev tool"
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"No feat/fix/perf/revert or breaking commit since v1.2.3."* ]]
	[[ "$output" == "## v1.2.4"* ]]
	[[ "$output" == *'- CVE-2026-5 in `curl`'* ]]
	[[ "$output" == *"update a dev tool"* ]]
	grep -qx 'debian:13-slim@sha256:aaa' "$TRIVY_LOG"
}

@test "rebuild: the release tag is annotated, so the next run waits a week" {
	export GITHUB_ACTIONS=true GITHUB_REPOSITORY=example/app GITHUB_TOKEN=secret AUTO_RELEASE_DISPATCH=false
	export AUTO_RELEASE_PUSH_URL="$BATS_TEST_TMPDIR/remote.git"
	export AUTO_RELEASE_STRATEGY=conventional AUTO_RELEASE_IMAGE=ghcr.io/example/app
	export STUB_VULNS_1_2_3="CVE-2026-5 curl" STUB_VULNS_1_2_4="CVE-2026-5 curl" STUB_VULNS_3_24_3=""
	# A job container without a git identity.
	unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
	export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true
	dockerfile 'FROM alpine:3.24.3' 'RUN apk add --no-cache curl'
	GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com commit "feat: add a Dockerfile"
	old_tag_identity() { GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com old_tag "$@"; }
	old_tag_identity v1.2.3
	run --separate-stderr "$AUTO_RELEASE" release
	[ "$status" -eq 0 ]
	[ "$(git cat-file -t v1.2.4)" = tag ]
	[[ "$(git cat-file -p v1.2.4)" == *"tagger auto-release <auto-release@localhost>"* ]]
	[ -n "$(git ls-remote --tags "$BATS_TEST_TMPDIR/remote.git" 'v1.2.4^{}')" ]
	grep -q '"body":"### Security fixes in the image' "$STUB_LOG"
	run --separate-stderr "$AUTO_RELEASE" plan
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[[ "$stderr" == *"v1.2.4 is 0 days old"* ]]
}
