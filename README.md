# Pipelines

GitHub Actions CI/CD for Dockerised apps: build → push to ghcr.io → deploy to a VPS running Docker Swarm + Traefik, with healthcheck and automatic rollback. 

Also npm package releases with trusted publishing, and browser extension CI and store releases.

`generate.sh` (apps), `generate-package.sh` (npm packages) and `generate-extension.sh` (browser extensions) write the workflows into a target repository's `.github/`.

## Usage

```sh
./generate.sh --target <repo> --mode solo|monorepo --domain <host> --port <n> [options]
```

Run `./generate.sh --help` for every option.

### Solo repo (one app at the repo root)

```sh
./generate.sh --target ../my-app --mode solo --domain my-app.com --port 8080 --test-cmd "npm test"
```

Writes `deploy-staging.yml` + `deploy-production.yml` (or `deploy.yml` with `--pipeline direct`). The workflows run on every push to their branch. Dockerfile defaults to `tools/docker/Dockerfile`. The repo is the app: the stack is `<repo>-<stack>` and the image `ghcr.io/<owner>/<repo>` (`-client`/`-server` for fullstack), `--service` only names the workflows and the VPS stack files.

### Monorepo (run once per app)

```sh
./generate.sh --target ../mono --mode monorepo --service website --domain example.com --port 9090 \
  --extra-path "resources/**" --test-cmd "npm run testin-nutin -w website"
./generate.sh --target ../mono --mode monorepo --service tutorial --pipeline direct \
  --domain todo.example.com --port 9092
```

Writes `deploy-staging-<service>.yml` + `deploy-production-<service>.yml` (or `deploy-<service>.yml`). Names include the service: stack `<repo>-<service>-<stack>`, image `ghcr.io/<owner>/<repo>-<service>`. Each workflow only runs when `<app-dir>/**` (default `apps/<service>`), an `--extra-path` or the workflow file itself changes. Dockerfile defaults to `<app-dir>/tools/docker/Dockerfile`.

## App types (`--type`)

- **frontend** (default): one container, routed at `/`.
- **backend**: a server container routed at `/`. Server dir defaults to `.` (solo) / `apps/<service>` (monorepo), Dockerfile to `<server-dir>/Dockerfile`.
- **fullstack**: client routed at `/` (`--port`) and server routed at `--server-path` prefixes (default `/api`, `--server-port`), in one stack. Dirs default to `apps/client` + `apps/server` (solo) / `apps/<service>-client` + `apps/<service>-server` (monorepo).

```sh
# paris-2024 shape
./generate.sh --target ../shop --mode solo --type fullstack --domain shop.com --port 4222 --server-port 3000 \
  --server-path /api --server-path /docs --db postgres --migrations-cmd "node scripts/run-migrations/index.cjs" \
  --server-replicas 2 --extra-path "libs/**" --extra-path package-lock.json --pr-test-cmd "npx nx run-many -t test"
```

Backend/fullstack apps get their own `stacks/<service>.yml`: add app-specific env variables and secrets there (it's kept on re-runs without `--force`). Options:

- `--db postgres`: postgres service + DB Docker secrets; the database is backed up (encrypted, `ENCRYPTION_PASSWORD`) before each deployment and that backup is restored on rollback.
- `--migrations-cmd "<cmd>"`: one-shot service running `<cmd>` with `sh -c` in the server image on each new server image.
- `--server-replicas <n>`: server scaled to `n` once the stack is healthy.
- Fullstack staging builds only rebuild the client/server whose dir changed since `main` (both when an `--extra-path` changed, or when neither did); the other image keeps its previous tag. The direct pipeline always rebuilds both.

`--pr-test-cmd "<cmd>"` (any type) adds a workflow running `<cmd>` on pull requests to `staging` (staging pipeline) or `main` (direct).

## Pipelines

- **staging** (default): pushes to `staging` test, build and deploy to `--staging-domain` / `--staging-port` (default `staging.<domain>` / `<port>+1`). Pushes to `main` redeploy the staging image tags to production (no rebuild), then remove the staging stack. Also generates `restrict-main-pr.yml` (PRs to `main` must come from `staging`) and `recreate-staging.yml` (recreates `staging` from `main` after a production deploy).
- **direct**: pushes to `main` test, build and deploy to production.

Both clean old ghcr.io image versions of the app (`--keep-images`, default 3).

## Re-running

- An app's files (workflows, PR test workflow, `stacks/<service>.yml`) are never overwritten without `--force`. With `--force`, the app's previous files are removed first, so this is also how an app switches pipeline or type.
- Shared files (`scripts/`, `stacks/stack.yml`, `docs/WORKFLOWS.md`, `restrict-main-pr.yml`) are kept when present, refreshed with `--force`. Kept files that differ from the kit are listed: re-run with `--force` to update them (e.g. a repo generated before backend/fullstack support needs the newer `healthcheck.sh`).
- `recreate-staging.yml` is rebuilt on every run from all `deploy-production*.yml` files, and removed (with `restrict-main-pr.yml`) when no app uses the staging pipeline anymore.
- Shared scripts and stacks are only generated while an app in the repo uses them (staging pipeline, backend/fullstack, database, frontend), and removed once none does. See `docs/WORKFLOWS.md` ("Generated scripts") for the list.
- A warning is printed when a port is already used by another app's workflow.

## Packages (`generate-package.sh`)

```sh
./generate-package.sh --target <repo> --mode solo|monorepo [--package-dir <dir>] [options]
```

Writes `release.yml` (solo) or `release-<name>.yml` (monorepo, one run per package), publishing the package to npm when a `<tag-prefix><version>` tag is pushed, plus the shared `docs/PACKAGES.md`.

```sh
# a11y-elements shape: tag v1.2.3, package at the repo root
./generate-package.sh --target ../a11y-elements --mode solo \
  --check "npm run typecheck" --check "npm test" --check "npm run validate:pack"
# nutin shape: tag cli-v3.0.0, package in packages/nutin
./generate-package.sh --target ../nutin --mode monorepo --package-dir packages/nutin --tag-prefix cli-v --skip-main-check
```

- `--name`: names the workflow, its file (monorepo) and its concurrency group. Default: the `package.json` name as a slug (solo), the package dir's basename (monorepo).
- `--tag-prefix`: default `v` (solo), `<name>-v` (monorepo). A prefix overlapping another workflow's tag filter is refused, as one tag would publish both packages.
- `--check "<cmd>"` (repeatable): pre-publish steps, run in order in the package dir after `npm ci` (repo root).
- `--skip-main-check`: also publish tags whose commit isn't on `main`.
- The workflow checks the tag against the package's `package.json` version, lists the tarball (`npm pack --dry-run`) and runs `npm publish --access public` from the package dir.
- npm authenticates with GitHub's OIDC token (no npm token secret): add the workflow as trusted publisher in the package's npm settings. The package must already exist on npm, so its first version is published manually.

## Extensions (`generate-extension.sh`)

```sh
./generate-extension.sh --target <repo> [options]
```

Writes `ci.yml` (pushes to `main` and pull requests), `release.yml` (`vX.Y.Z` tags), the `build-extension` composite action, `dependabot.yml` and `docs/EXTENSIONS.md` into a repo whose root is the extension (`package.json` + `.nvmrc`). The defaults reproduce notelet (a Nutin project), so a Nutin extension only needs `--target`.

```sh
# notelet shape: Chrome + Firefox, both stores
./generate-extension.sh --target ../notelet
# Chrome only, GitHub Release without store submission, own scripts
./generate-extension.sh --target ../my-ext --browser chrome --no-chrome-store \
  --check "npm run typecheck" --check "npm test" --package-cmd 'npm run package -- "$BROWSER"' --validate-cmd ""
```

- CI: a `check` job (`npm ci`, then each `--check`), then one build per `--browser` (default both): package, validate, lint (Firefox), then package again and compare the ZIP checksums (reproducible build, `SOURCE_DATE_EPOCH` pinned to the last commit).
- The repo provides the commands (`--package-cmd`, `--validate-cmd`, `--lint-cmd`; `""` drops validation/lint). They run with `$BROWSER`, plus `$TAG` for the validation. Packaging writes `dist/<name>-<browser>-<version>.zip`, its `.zip.sha256` and the unpacked `dist/<browser>/`.
- Pass commands in single quotes (`--package-cmd 'npm run package -- "$BROWSER"'`), so `$BROWSER` isn't expanded by your shell when generating.
- `--name`: ZIP and artifact prefix (default: `package.json` name). `--title`: release title (default: the name, capitalized).
- Release: CI with the tag, GitHub Release with every ZIP and checksum, then Chrome Web Store / Firefox Add-ons submission in jobs using the `store` environment (secrets and manual approval there). `--no-chrome-store` / `--no-firefox-store` drop a store job. Firefox Add-ons get a `git archive` of the tagged commit as source code, unless `--no-source-archive`.
- The workflows and the action are never overwritten without `--force`; `dependabot.yml` and `docs/EXTENSIONS.md` are shared files (kept, listed when they differ from the kit).

## Requirements

- GitHub secrets: `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`, `SSH_PASS`, `SSH_PORT`, `DOCKER_AUTH`, plus `ENCRYPTION_PASSWORD` with `--db` (see the generated `.github/docs/WORKFLOWS.md`).
- VPS: Docker Swarm, Traefik on the external `traefik-public` network with a `letsencrypt` cert resolver and a `websecure` entrypoint.
- With `--db`: the DB Docker secrets (`generate.sh` prints the commands) and a `/backups` dir writable by the SSH user.
- Every routed container must answer `GET /health` on its port (Swarm healthcheck uses `wget`, e.g. busybox in alpine images; Debian `-slim` images have neither `wget` nor `curl`). Migrations run with `sh -c`, so the server image needs a shell.
- Tests (`--test-cmd`, `--pr-test-cmd`) run after `npm ci`, so the repo needs a `package-lock.json`.

## Layout

```
generate.sh            apps
generate-package.sh    npm packages
generate-extension.sh  browser extensions
lib/common.sh          helpers shared by the generators
templates/
  workflows/   deploy-staging.yml, deploy-production.yml, deploy-direct.yml (frontend), recreate-staging.yml, restrict-main-pr.yml, pr-tests.yml, release-package.yml
    stack/     deploy-staging.yml, deploy-production.yml, deploy-direct.yml (backend/fullstack)
    extension/ ci.yml, release.yml, chrome-web-store.yml + firefox-addons.yml (appended to release.yml), source-archive.yml (ci.yml step)
  actions/     build-extension/: action.yml, validate.yml + lint.yml (its optional steps) (extensions)
  dependabot.yml (extensions)
  stacks/      stack.yml (frontend, envsubst'd in CI)
    fragments/ assembled into stacks/<service>.yml for backend/fullstack apps
  scripts/     jobs/ (run in GitHub Actions), deployment/ + db-backup/ (copied to and run on the VPS)
  docs/        WORKFLOWS.md (apps), PACKAGES.md (packages), EXTENSIONS.md (extensions)
```

Templates use `__TOKEN__` placeholders, filled by the `generate*.sh` scripts. A line that is only `__NAME__` (possibly indented) is replaced by a multi-line block, indented like it (or dropped).
