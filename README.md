# byld-flarum-image

The Flarum 2.x image that byld deploys for a one-click forum, published publicly so that a
byld node can pull it without holding a registry credential.

Published to `ghcr.io/eliasl-git/byld-flarum-image`. The image is built from the recipe in
this repository by `.github/workflows/publish.yml`, either on a push to `main` or on demand
from the Actions tab with a tag.

## Why byld builds its own

Flarum 2.0 is the first release that supports PostgreSQL. byld offers a Postgres database as
an alternative to running a MariaDB container beside the app, and the community image used
for Flarum 1.8 cannot do it: it has no 2.x tag, its entrypoint hardcodes the MySQL driver,
and it probes the database with the `mariadb` client. None of that is overridable by
configuration, so supporting Postgres means a different image.

## What it contains

- FrankenPHP on PHP 8.3, with every extension Flarum needs installed at build time so
  nothing is fetched at deploy.
- `flarum/flarum` 2.0.0 resolved with `composer create-project`, so the dependency tree is
  fixed at build time.
- An entrypoint that reads its whole configuration from the environment: it waits for the
  database, installs Flarum on first boot with the administrator account it is given, and
  starts the server on port 8000. It writes nothing to disk except the config, storage and
  published assets on the volume.

The container runs as `www-data` and needs no capabilities beyond `CHOWN`, `SETUID` and
`SETGID`, so it runs under a `no-new-privileges` policy.

## Configuration

Read from the environment at start:

- `DB_DRIVER`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_PREFIX`
- `FLARUM_BASE_URL`, `FLARUM_FORUM_TITLE`
- `FLARUM_ADMIN_USER`, `FLARUM_ADMIN_PASS`, `FLARUM_ADMIN_EMAIL`

The entrypoint's own variables are prefixed `BYLD_`; they are how the entrypoint hands the
values to the installer, not something to set.
