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
	unset AUTO_RELEASE_STRATEGY AUTO_RELEASE_IMAGE AUTO_RELEASE_TOKEN AUTO_RELEASE_DRY_RUN

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
	chmod +x stubs/*
	export PATH="$BATS_TEST_TMPDIR/stubs:$PATH" STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
	: >"$STUB_LOG"

	git init -q --bare remote.git
	git init -q -b main repo
	cd repo
	git remote add origin "$BATS_TEST_TMPDIR/remote.git"
	commit "chore: initial commit"
}

commit() { git commit -q --allow-empty -m "$1"; }

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
	commit "chore(deps): update python from 3.14.7 to 3.14.8 (patch) (#7)"
	next_tag
	[ "$next" = v1.2.4 ]
	[[ "$output" == *"update python from 3.14.7 to 3.14.8"* ]]
	[[ "$output" != *"(digest)"* ]]
	[[ "$output" != *"lockFileMaintenance"* ]]
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
