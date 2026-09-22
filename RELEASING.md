# Releasing

This project ships through tag-driven CI. A tag of the form
`v{REPO_VERSION}+wispr{WISPR_FLOW_VERSION}` on `main` triggers the publish chain
in [`.github/workflows/ci.yml`](.github/workflows/ci.yml), which builds both
architectures, attaches the artifacts to a GitHub Release, and updates the APT,
DNF, and AUR repositories. Pushes to branches/PRs run only the lint/unit gates.

```bash
# Cut a project release once the prerequisites below are in place:
gh variable set REPO_VERSION --body "1.0.1"
git tag "v1.0.1+wispr$(gh variable get WISPR_FLOW_VERSION)"
git push origin "v1.0.1+wispr$(gh variable get WISPR_FLOW_VERSION)"
```

## One-time prerequisites

Before the first real release:

- **Repo variables**

  ```bash
  gh variable set REPO_VERSION         --body "1.0.0"   # wrapper version
  gh variable set WISPR_FLOW_VERSION   --body "1.5.695"  # tracked upstream version
  ```

- **Secrets**
  - `REPO_GPG_PRIVATE_KEY` — armored private key; signs both the APT
    `Release`/`InRelease` and the DNF `repomd.xml`. Put its key id in the
    `gh-pages` `conf/distributions` `SignWith:` field.
  - `AUR_SSH_PRIVATE_KEY` — deploy key registered on the
    `wispr-flow-appimage` AUR account.
  - `GH_PAT` — a PAT with `repo` + `workflow` scope. `check-wispr-version` and
    `update-flake-lock` use it; a tag pushed with the default `GITHUB_TOKEN`
    would **not** re-trigger the tag-driven workflow.

- **`gh-pages` branch** — an orphan branch holding the published repo metadata.
  GitHub Pages does **not** need to be enabled: the Worker reads metadata from
  this branch via `raw.githubusercontent.com` and the smoke tests/heartbeat hit
  `pkg.wispr-flow-linux.dev` directly. Seed it from a throwaway clone so your
  working tree is untouched (a plain `git switch --orphan` would stage the whole
  repo into the branch):

  ```bash
  wt=$(mktemp -d)
  git clone -q "$(git remote get-url origin)" "$wt/ghp"
  git -C "$wt/ghp" switch --orphan gh-pages
  git -C "$wt/ghp" rm -rf . >/dev/null 2>&1 || true
  mkdir -p "$wt/ghp/conf"
  cat > "$wt/ghp/conf/distributions" <<'EOF'
  Origin: wispr-flow-linux
  Label: Wispr Flow for Linux (unofficial)
  Codename: stable
  Architectures: amd64 arm64
  Components: main
  Description: Unofficial Wispr Flow Linux packages
  SignWith: 087A3E441F1EBABFD1EBC2A21EBFB09D261977F9
  EOF
  touch "$wt/ghp/.nojekyll"
  git -C "$wt/ghp" add -A
  git -C "$wt/ghp" commit -m "Bootstrap gh-pages repo tree"
  git -C "$wt/ghp" push -u origin gh-pages
  rm -rf "$wt"
  ```

- **AUR package** — create `wispr-flow-appimage` on aur.archlinux.org. The CI
  copies [`scripts/aur/PKGBUILD.template`](scripts/aur/PKGBUILD.template) into
  the checkout each release, so the AUR repo only needs to exist.

- **Worker** — the `wispr-flow-linux/worker` repo deploys the Cloudflare Worker
  at `pkg.wispr-flow-linux.dev` (see that repo's README). Until it's live, the
  APT/DNF jobs keep the binaries in `gh-pages` and the smoke tests skip; once
  live, binaries are stripped and served by 302-redirect to Release assets.

## Release flavors

- **Upstream-tracking retag (no human action).** `check-wispr-version` runs
  daily: it reads upstream's release manifest
  (`dl.wisprflow.com/wispr-flow/win32/latest.json`, via
  `scripts/setup/resolve-installer-url.sh`), and when the version or digest
  there differs from the installer pin in `scripts/setup/installer-pin.sh`, or
  the version differs from `WISPR_FLOW_VERSION`, it rewrites the pin (version,
  URL and SHA-256 together, via `scripts/setup/write-installer-pin.sh`), bumps
  the version in `nix/wispr-flow.nix`, commits, updates the variable, and
  pushes a new tag with the same `REPO_VERSION` and a new `+wispr{X.Y.Z}`
  suffix. A manifest without a digest never bumps. These don't get CHANGELOG
  entries — the tag suffix tracks them. To bump by hand, run the same
  pipeline locally and commit the result:

  ```bash
  scripts/setup/resolve-installer-url.sh | scripts/setup/write-installer-pin.sh
  ```

  Every build (local and CI) downloads exactly what the pin says and fails on
  a digest mismatch, so a build can never quietly pick up an un-audited
  upstream release. The workflow is also the only thing that tags on its own:
  merging a working pin to `main` re-arms it.

- **Project release.** You bumped `REPO_VERSION` because you shipped wrapper or
  packaging changes. Follow the checklist below.

- **Release candidate (manual look-first).** Push a tag with an `-rc` suffix
  on the wrapper version, e.g. `v1.0.4-rc.1+wispr1.6.897`. CI runs the full
  build and artifact tests and creates a GitHub **pre-release** carrying the
  same assets the final tag would (the `-rc.N` is dropped from the package
  version), but the APT, DNF and AUR jobs skip it, so nothing reaches a
  package repo. Inspect the pre-release, then push the real tag. The bump
  workflow never produces rc tags, and release notes skip pre-releases when
  picking the previous tag. See D-011 in
  [`docs/decisions.md`](docs/decisions.md).

## Pre-release checklist (project release)

1. **CI is green on `main`** (`gh run list --branch main --limit 5`).
2. **`CHANGELOG.md` updated** — move `[Unreleased]` under a new
   `[v{REPO_VERSION}]` heading with today's date.
3. **Local lint/tests pass** — `bats tests/` and the shellcheck command in
   [`CLAUDE.md`](CLAUDE.md).
4. **Versions in sync** — `gh variable get WISPR_FLOW_VERSION` matches
   `WISPR_VERSION` in `scripts/setup/installer-pin.sh`. If not, pull `main`
   (the `check-wispr-version` workflow may have bumped it).

## What CI does on a tag push

After the gate jobs pass, the [`ci.yml`](.github/workflows/ci.yml) chain:

1. Builds deb/rpm/AppImage for amd64 and arm64 — each build downloads the
   pinned proprietary installer, verifies its SHA-256, and stages the pinned
   prebuilt helper.
2. Runs the format validators (`tests/test-artifact-*.sh`).
3. Creates the GitHub Release and attaches the six packages.
4. Hands off to `update-apt-repo`, `update-dnf-repo`, and `update-aur-repo`,
   which sign and publish to the Cloudflare-fronted package repos. These
   three skip `-rc` tags; the Release is created as a pre-release instead.

## After the release lands

- **Verify the Release page** — six assets, sizes look right, notes rendered.
- **Smoke-test one artifact** — download the AppImage and run `--doctor`.
- **Watch `apt-repo-heartbeat`** — the daily run validates the redirect chain
  end-to-end and opens a tracking issue on failure.

## If something goes wrong mid-release

- **Build failed.** Push the fix to `main`, then re-tag with a new `+wispr`
  suffix (or a `+rebuild.N` suffix if upstream hasn't moved). Releases are
  append-only; the original tag stays.
- **A bad release shipped.** Mark the GitHub Release as a pre-release/draft and
  ship a follow-up; don't delete assets that the Worker may already be caching.
