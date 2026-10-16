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
- `flarum/flarum` 2.0.0, installed from the committed `composer.json` and `composer.lock`
  rather than resolved at build time. The skeleton requires `flarum/core: ^2.0.0` and every
  extension as `*` and ships no lock of its own, so a plain `composer create-project` picks
  whatever is newest that day: two builds of the same tag two days apart produced
  `flarum/core` 2.0.0 and 2.0.1, and a forum whose database records 2.0.0 answers **503
  "Update Flarum"** to every visitor once its container is replaced. The lock is what makes
  a rebuild safe.
- An entrypoint that reads its whole configuration from the environment: it waits for the
  database, installs Flarum on first boot with the administrator account it is given, and
  starts the server on port 8000. It writes nothing to disk except the config, storage and
  published assets on the volume.

## Versions

`IMAGE_VERSION` holds the tag to publish, and it is the **image's** version rather than
Flarum's: `2.0.0-1` is Flarum 2.0.0 in the first build of this image. The two are separate
because the image changes for reasons that have nothing to do with Flarum - the entrypoint's
boot path, the proxy's cache headers - and because byld pulls an image only when the tag is
absent on the node, so republishing under an existing tag reaches nobody who already has it.

Bump `IMAGE_VERSION` to publish a new build; a push to `main` builds and publishes whatever
it holds. Keeping the Flarum version in the tag is deliberate: a tag reading `2.0.1` invites
someone to bump `FLARUM_VERSION` to match, which upgrades every forum's code out from under a
database that records the old version and serves them all a 503.

The container runs as `www-data` and needs no capabilities beyond `CHOWN`, `SETUID` and
`SETGID`, so it runs under a `no-new-privileges` policy.

## Configuration

Read from the environment at start:

- `DB_DRIVER`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_PREFIX`
- `FLARUM_BASE_URL`, `FLARUM_FORUM_TITLE`
- `FLARUM_ADMIN_USER`, `FLARUM_ADMIN_PASS`, `FLARUM_ADMIN_EMAIL`

The entrypoint's own variables are prefixed `BYLD_`; they are how the entrypoint hands the
values to the installer, not something to set.
