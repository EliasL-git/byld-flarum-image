# byld's Flarum image (Flarum 2.x).
#
# Why byld owns this image rather than pointing at a community one:
#
# Flarum 2.0 is the first release that supports PostgreSQL. byld offers a
# Postgres database as an alternative to running a MariaDB container beside the
# app, and the community image byld used for Flarum 1.8 cannot do it: it has no
# 2.x tag, its entrypoint hardcodes `'driver' => 'mysql'`, and it probes the
# database with the `mariadb` client. There is no env var to override either, so
# pointing it at Postgres is not a configuration change, it is a different image.
#
# What is pinned, and why each one:
#
#   * the base image, by digest-free tag but with the PHP minor fixed, so a
#     rebuild does not silently move the interpreter;
#   * the Flarum version, exactly - not a range - so the tree a deploy pulls is
#     the tree that was tested;
#   * every PHP extension at build time, so nothing is fetched at deploy.
#
# The container runs as `www-data` and nothing else. byld drops every capability
# and adds back only CHOWN/SETUID/SETGID, and it reads this image's `Config.User`
# to decide which user an app runs as and who owns the app's data directory. An
# image that ran as root and chowned a directory to another user would then need
# DAC_OVERRIDE to write into it, which is exactly the trap the Flarum 1.8 entry
# fell into. Running as www-data throughout means the app writes only what it
# owns and needs no capability beyond the base set.

ARG PHP_VERSION=8.3
FROM dunglas/frankenphp:1-php${PHP_VERSION}-bookworm

ARG FLARUM_VERSION=2.0.0

# Flarum 2.0 requires PHP ^8.3 with curl, dom, fileinfo, gd, json, mbstring,
# openssl, pdo, tokenizer and zip. curl/dom/json/mbstring/openssl/tokenizer ship
# in the base image; these are the ones that do not. Both PDO drivers are here
# because Flarum supports MySQL, MariaDB, PostgreSQL and SQLite and byld offers
# more than one of them as a database choice.
RUN install-php-extensions gd zip pdo_mysql pdo_pgsql intl @composer

ENV FLARUM_ROOT=/flarum \
    FLARUM_DATA=/data

# The application tree is immutable and lives in the image, so a redeploy starts
# from a known state. Only config, storage and published assets are on the
# volume. `create-project` rather than a git clone: it resolves the dependency
# tree at build time and the result is what composer would install for that tag.
RUN composer create-project "flarum/flarum:${FLARUM_VERSION}" "$FLARUM_ROOT" \
      --no-interaction --no-progress --prefer-dist \
 && mkdir -p "$FLARUM_DATA/storage" "$FLARUM_DATA/assets" \
 && chown -R www-data:www-data "$FLARUM_ROOT" "$FLARUM_DATA"

COPY Caddyfile /etc/frankenphp/Caddyfile
COPY entrypoint.sh /usr/local/bin/byld-entrypoint
RUN chmod 0755 /usr/local/bin/byld-entrypoint

# FrankenPHP's binary carries cap_net_bind_service so that it can bind port 80 as
# a non-root user. This image only ever listens on 8000, which needs no
# capability, and the capability is actively harmful here: byld runs an app with
# `no-new-privileges`, and the kernel refuses to execute a binary carrying file
# capabilities under that policy at all - so the container would install itself
# correctly and then die with "Operation not permitted" trying to start.
RUN setcap -r /usr/local/bin/frankenphp \
 && [ -z "$(getcap /usr/local/bin/frankenphp)" ] \
 && echo "frankenphp carries no file capabilities"

# FrankenPHP keeps its own state under XDG dirs; point them at the volume so a
# restart does not try to write outside the one directory the app owns.
ENV XDG_DATA_HOME=/data/caddy \
    XDG_CONFIG_HOME=/data/caddy

USER www-data
EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/byld-entrypoint"]
