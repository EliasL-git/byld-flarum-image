#!/bin/bash
# byld's Flarum entrypoint.
#
# Two jobs, in order: make the app's own state survive a redeploy, and install
# Flarum the first time it is asked to serve.
#
# State: the application tree in the image is immutable, so everything Flarum
# writes at runtime - its config, its storage and its published assets - is put
# on the app's volume and symlinked back into the tree. A redeploy therefore
# starts from the image's tree plus the forum that was already there, rather than
# from an empty forum.
#
# Install: Flarum 2.0 can install itself without a human, from a config file, via
# `php flarum install --file=...`. That is the whole reason this image can be a
# one-click deploy. The file is built here from the app's environment, written
# where only this container can read it, and removed as soon as it has been used,
# because it holds the database password and the first administrator's password.
set -euo pipefail

FLARUM_ROOT="${FLARUM_ROOT:-/flarum}"
DATA="${FLARUM_DATA:-/data}"
CONFIG="$DATA/config.php"

log() { printf '[flarum] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# State on the volume
# ---------------------------------------------------------------------------

mkdir -p "$DATA/storage" "$DATA/assets" "$DATA/caddy"

# Anything the image shipped in these paths moves onto the volume the first time,
# so the volume is a superset of the image rather than a replacement for it.
if [ -d "$FLARUM_ROOT/public/assets" ] && [ ! -L "$FLARUM_ROOT/public/assets" ]; then
  cp -a "$FLARUM_ROOT/public/assets/." "$DATA/assets/" 2>/dev/null || true
  rm -rf "$FLARUM_ROOT/public/assets"
fi

ln -sfn "$DATA/storage" "$FLARUM_ROOT/storage"
ln -sfn "$DATA/assets" "$FLARUM_ROOT/public/assets"

# ---------------------------------------------------------------------------
# The database
# ---------------------------------------------------------------------------

driver="${DB_DRIVER:-mysql}"

case "$driver" in
  pgsql|postgres|postgresql) pdo_driver=pgsql ;;
  mysql|mariadb)             pdo_driver=mysql ;;
  *)
    log "DB_DRIVER '$driver' is not one Flarum supports (mysql, mariadb, pgsql)"
    exit 1
    ;;
esac

db_host="${DB_HOST:-}"
db_port="${DB_PORT:-3306}"
db_name="${DB_NAME:-flarum}"
db_user="${DB_USER:-flarum}"
db_password="${DB_PASSWORD:-}"
db_prefix="${DB_PREFIX:-}"
db_search_path="${DB_SEARCH_PATH:-public}"

if [ -z "$db_host" ]; then
  log "DB_HOST is required"
  exit 1
fi

# The password is passed in the environment rather than as an argument: an
# argument is world-readable in /proc while the process runs, the environment is
# not. The DSN is a plain string, so it goes the same way.
wait_for_db() {
  local waited=0
  log "waiting for $pdo_driver at $db_host:$db_port"
  while :; do
    if BYLD_DSN="$pdo_driver:host=$db_host;port=$db_port;dbname=$db_name" \
       BYLD_DB_USER="$db_user" \
       BYLD_DB_PASSWORD="$db_password" \
       php -r '
         try {
           new PDO(getenv("BYLD_DSN"), getenv("BYLD_DB_USER"), getenv("BYLD_DB_PASSWORD"), [
             PDO::ATTR_TIMEOUT => 5,
             PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
           ]);
           exit(0);
         } catch (Throwable $e) {
           exit(1);
         }
       ' 2>/dev/null; then
      log "the database is answering"
      return 0
    fi

    waited=$((waited + 2))
    if [ "$waited" -ge 180 ]; then
      log "the database did not answer within ${waited}s; giving up"
      return 1
    fi
    sleep 2
  done
}

# ---------------------------------------------------------------------------
# Install, once
# ---------------------------------------------------------------------------

install_flarum() {
  log "first boot: installing Flarum"

  # Built with PHP rather than by hand so a password containing a quote, a
  # backslash or a newline cannot break the file or the shell.
  BYLD_BASE_URL="${FLARUM_BASE_URL:-}" \
  BYLD_ADMIN_USER="${FLARUM_ADMIN_USER:-admin}" \
  BYLD_ADMIN_PASS="${FLARUM_ADMIN_PASS:-}" \
  BYLD_ADMIN_EMAIL="${FLARUM_ADMIN_EMAIL:-}" \
  BYLD_TITLE="${FLARUM_FORUM_TITLE:-Forum}" \
  BYLD_DRIVER="$pdo_driver" \
  BYLD_DB_HOST="$db_host" \
  BYLD_DB_PORT="$db_port" \
  BYLD_DB_NAME="$db_name" \
  BYLD_DB_USER="$db_user" \
  BYLD_DB_PASSWORD="$db_password" \
  BYLD_DB_PREFIX="$db_prefix" \
  BYLD_DB_SEARCH_PATH="$db_search_path" \
  php -r '
    $config = [
      "debug" => false,
      "baseUrl" => getenv("BYLD_BASE_URL"),
      "databaseConfiguration" => [
        "driver" => getenv("BYLD_DRIVER"),
        "host" => getenv("BYLD_DB_HOST"),
        "port" => (int) getenv("BYLD_DB_PORT"),
        "database" => getenv("BYLD_DB_NAME"),
        "search_path" => getenv("BYLD_DB_SEARCH_PATH"),
        "username" => getenv("BYLD_DB_USER"),
        "password" => getenv("BYLD_DB_PASSWORD"),
        "prefix" => getenv("BYLD_DB_PREFIX"),
      ],
      "adminUser" => [
        "username" => getenv("BYLD_ADMIN_USER"),
        "password" => getenv("BYLD_ADMIN_PASS"),
        "email" => getenv("BYLD_ADMIN_EMAIL"),
      ],
      "settings" => [
        "forum_title" => getenv("BYLD_TITLE"),
      ],
      // No queue worker runs beside this app, so jobs are done inline. A queued
      // driver here would silently drop them.
      "queue" => ["driver" => "sync"],
    ];

    $path = "/tmp/flarum-install.json";
    file_put_contents($path, json_encode($config, JSON_PRETTY_PRINT));
    chmod($path, 0600);
  '

  ( cd "$FLARUM_ROOT" && php flarum install --file=/tmp/flarum-install.json )
  rm -f /tmp/flarum-install.json

  # The installer writes config.php into the project root, which is in the image
  # and therefore lost on the next container. Move it onto the volume and leave
  # a symlink in its place.
  if [ -f "$FLARUM_ROOT/config.php" ]; then
    mv -f "$FLARUM_ROOT/config.php" "$CONFIG"
  fi

  log "install finished"
}

if [ -f "$CONFIG" ]; then
  log "an existing forum was found on the volume"
else
  wait_for_db || exit 1
  install_flarum
fi

ln -sfn "$CONFIG" "$FLARUM_ROOT/config.php"

# ---------------------------------------------------------------------------
# Flarum's caches, and when to throw them away
# ---------------------------------------------------------------------------
#
# Flarum compiles a service container and publishes its assets on first use, and
# both are keyed to the application tree. A cache left over from a *different*
# image is worse than none and has to go - but clearing it on every boot is a
# different thing, and it was costing the forum its whole start. Measured on this
# platform, as "how long until a visitor actually gets a page", which is the only
# figure a user experiences: at 0.1 vCPU the page arrived **21.9 seconds** after the
# container started, against **6.9** with the stamp; at 0.5 vCPU, 4.6 against 2.1.
# On a container restarted for a redeploy, a restart or a host reboot, that was paid
# for nothing - the tree had not changed.
#
# So the stamp records which image the cache belongs to. A boot under the same
# image keeps it; a boot under a different one clears it, once.
STAMP="$DATA/.byld-flarum-image"
IMAGE_ID="${FLARUM_IMAGE_STAMP:-unset}"

if [ -f "$CONFIG" ]; then
  if [ "$(cat "$STAMP" 2>/dev/null || true)" = "$IMAGE_ID" ]; then
    log "the cache belongs to $IMAGE_ID; keeping it"
  else
    log "the cache is from another image; clearing it"
    ( cd "$FLARUM_ROOT" && php flarum cache:clear ) >/dev/null 2>&1 || true
    printf '%s' "$IMAGE_ID" > "$STAMP"
  fi
fi

log "starting on :8000"

# Run the server in the background rather than `exec`ing it, so the opcode cache can
# be warmed before the first visitor arrives - and forward the stop signal, so
# `docker stop` is still a graceful shutdown rather than a kill after the timeout.
frankenphp run --config /etc/frankenphp/Caddyfile &
SERVER_PID=$!
trap 'kill -TERM "$SERVER_PID" 2>/dev/null || true' TERM INT

# Starting the container empties PHP's opcode cache, so the first request after a
# redeploy, a restart or a host reboot compiles the whole application: measured at
# 0.5 vCPU, **0.61 seconds**, against **0.05** once it is warm. Asking for the front
# page here hands that cost to the boot instead of to whoever arrives first.
#
# It delays nothing. `frankenphp run` is already serving when this loop starts, and
# the loop is what the entrypoint is waiting on, not the server - so the port answers
# throughout and byld's own readiness probe does not wait for this.
#
# It is the forum's own front page rather than a health endpoint, because the point
# is to compile what a real request compiles. A failure here is not fatal: the
# server is up either way, and a forum that cannot answer its front page has a
# problem this loop is not going to fix.
for _ in $(seq 1 30); do
  if curl -fsS --max-time 5 -o /dev/null 'http://127.0.0.1:8000/' 2>/dev/null; then
    log "the front page is compiled and answering"
    break
  fi
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 1
done

wait "$SERVER_PID"
