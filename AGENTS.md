# AGENTS.md

Notes for coding agents working in this repository. [README.md](README.md) covers what
auto-release does, and [docs/decisions.md](docs/decisions.md) the rules it applies.

## Versioning

auto-release itself is plain SemVer: `vX.Y.Z` tags, image `X.Y.Z`, `X.Y` and `latest`, per
the [versioning standard](https://github.com/mbologna/.github/blob/main/VERSIONING.md).

- Never create, move or delete tags by hand, and never edit a version to release:
  auto-release tags its own releases from the commit types (`feat` minor; `fix`, `perf`,
  `revert` patch; `!` or a `BREAKING CHANGE:` footer major).
- Write Conventional Commit subjects; they decide the next version.
- auto-release implements the standard's tag schemes (`AUTO_RELEASE_METADATA_CMD`,
  `AUTO_RELEASE_UPSTREAM_CMD`). A change to how tags are found, ordered or formed must keep
  `VERSIONING.md` in mbologna/.github true, and is tested in `tests/auto-release.bats`.
