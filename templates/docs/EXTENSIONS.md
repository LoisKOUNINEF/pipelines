# Browser Extension Docs

`ci.yml` checks and packages the extension on pushes to `main` and on pull requests (a branch gets CI once it has a pull request). `release.yml` publishes it when a `vX.Y.Z` tag is pushed: a GitHub Release with the store ZIPs, then the Chrome Web Store and Firefox Add-ons submissions (those that were generated).

## CI (`ci.yml`)

* `check` job: `npm ci`, then the checks (build/type-check, tests…), in order.
* `build` job, one per browser (matrix): the `build-extension` composite action (`.github/actions/build-extension`):
  * Pins `SOURCE_DATE_EPOCH` to the last commit's timestamp.
  * Packages the extension, validates it, lints the Firefox build (addons-linter).
  * Removes `dist`, packages again and compares the ZIP checksums: the build must be reproducible.
* Uploads the ZIP, its checksum and the unpacked `dist/<browser>/` as the `<name>-<browser>` workflow artifact (7 days, 30 for a release).
* On a release, the Firefox build also creates the source archive (`git archive` of the tagged commit) that addons.mozilla.org reviewers rebuild the extension from.

## Commands the repository provides

The commands run with `BROWSER` (`chrome`/`firefox`) in their environment, and `TAG` (the release tag, empty outside releases) for the validation.

* Package: writes `dist/<name>-<browser>-<version>.zip`, its checksum `dist/<name>-<browser>-<version>.zip.sha256` (`sha256sum` format, file name relative to `dist`) and the unpacked extension in `dist/<browser>/`.
* Validate (optional): checks the package, and that its version matches `TAG` on a release.
* Lint (optional, Firefox only): e.g. `web-ext lint --source-dir dist/firefox`.
* The Firefox Add-ons job runs `npx web-ext sign`: keep `web-ext` in the devDependencies.

## Releasing

1. Bump the version in `package.json` and in the extension's `manifest.json`, commit and push.
2. Tag the commit and push the tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.

The workflow:

* Runs CI with the tag (the validation checks the package version against it).
* Creates the GitHub Release with every browser's ZIP and checksum (or replaces its assets when the release already exists, e.g. on a re-run).
* Submits to the stores, in jobs using the `store` environment: add required reviewers to it to approve each submission manually.

Releases of the same tag are queued, never run in parallel.

## Store secrets

Add them to the `store` environment (Settings → Environments → store):

* Chrome Web Store: `CWS_CLIENT_ID`, `CWS_CLIENT_SECRET`, `CWS_REFRESH_TOKEN` (an OAuth client with the Chrome Web Store API enabled), `CWS_PUBLISHER_ID`, `CWS_EXTENSION_ID`. The item must already exist: upload its first version manually from the developer dashboard. The upload is checked against its checksum, then submitted for review.
* Firefox Add-ons: `AMO_JWT_ISSUER`, `AMO_JWT_SECRET` (addons.mozilla.org → Developer Hub → API keys). Submitted to the listed channel without waiting for approval (`--approval-timeout 0`).
