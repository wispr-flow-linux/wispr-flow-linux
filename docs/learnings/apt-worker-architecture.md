[< Back to docs index](../index.md)

# APT/DNF distribution + the redirect Worker

Binary packages reach users through a Cloudflare Worker that 302-redirects to
GitHub Release assets, so the multi-hundred-MB Electron `.deb`/`.rpm` files never
get pushed to the `gh-pages` branch.

```
apt/dnf  ->  https://pkg.wispr-flow-linux.dev/...
                 │
                 ├─ /dists/*, /KEY.gpg, /rpm/*/repodata/*   ->  200 (passthrough
                 │                                               to gh-pages via
                 │                                               raw.githubusercontent.com)
                 └─ /pool/main/w/.../*.deb, /rpm/*/*.rpm     ->  302 to the
                                                                 GitHub Release asset
```

## Why the indirection

GitHub caps pushes at 100 MB per file; a packaged Electron app is well over
that. Publishing the binaries to `gh-pages` is therefore impossible. Instead the
publish jobs write only the *metadata* (the APT `Packages`/`Release`/`InRelease`
and the DNF `repodata`) to `gh-pages`, and a Worker intercepts requests for the
binaries themselves and redirects to the matching GitHub Release asset (no size
cap, served by GitHub's CDN). Binary bytes flow
`release-assets.githubusercontent.com → user` and never cross Cloudflare.

## How a filename maps to a release

Release tags are `v<repoVer>+wispr<wisprVer>`. The package filename embeds both
versions, so the Worker reconstructs the tag from the request path:

| Request path | Redirects to |
|---|---|
| `/pool/main/w/wispr-flow/wispr-flow_1.5.695-1.0.0_amd64.deb` | `.../releases/download/v1.0.0+wispr1.5.695/wispr-flow_1.5.695-1.0.0_amd64.deb` |
| `/rpm/x86_64/wispr-flow-1.5.695-1.0.0-1.x86_64.rpm` | `.../releases/download/v1.0.0+wispr1.5.695/wispr-flow-1.5.695-1.0.0-1.x86_64.rpm` |

This is why the build must pass `--release-tag` — without it the package
filename lacks the `-<repoVer>` segment the Worker's regex needs.

## The full redirect chain (and the heartbeat)

A binary URL walks: `pkg.wispr-flow-linux.dev` Worker `302` → GitHub Releases
`302` → CDN `200`. GitHub Pages is not involved — the canonical endpoint is the
Cloudflare-fronted domain, and the Worker reads metadata from `gh-pages` via
`raw.githubusercontent` (so the Pages feature need not be enabled). The
`apt-repo-heartbeat` workflow asserts each hop in order daily and checks the
fetched file's size against the Release asset, opening a tracking issue on
failure and closing it on recovery.

## Worker-liveness gating

The `update-apt-repo` / `update-dnf-repo` jobs probe the Worker before stripping
binaries from `gh-pages`:

- **Worker live** → strip the `.deb`/`.rpm` from the pool (the Worker serves
  them by redirect); metadata + signatures stay.
- **Worker not live** → keep the binaries in the pool so fetches don't 404.

So the system degrades safely both before the Worker is deployed and during an
outage.

## Where the pieces live

- **Metadata + signing:** `update-apt-repo` (reprepro) and `update-dnf-repo`
  (`createrepo_c` + `rpmsign`, repomd signed with the **primary** key — note the
  trailing `!` on the key id) in [`ci.yml`](../../.github/workflows/ci.yml).
- **Worker:** its own repo, `wispr-flow-linux/worker`.
- **Operations:** [`RELEASING.md`](../../RELEASING.md).
