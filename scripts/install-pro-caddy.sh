#!/usr/bin/env bash
#
# install-pro-caddy.sh — DEPRECATED.
#
# The pro.interactpak.com Caddy block is already configured on the VPS
# (Caddy 2.11.2 at /etc/caddy/Caddyfile, line 214 as of 2026-05-07):
#
#   pro.interactpak.com {
#       encode zstd gzip
#       root * /var/www/interactpro
#       file_server
#       @apk path *.apk
#       header @apk Content-Type application/vnd.android.package-archive
#       @plist path *.plist
#       header @plist Content-Type application/xml
#   }
#
# That block is exactly what we need: file-server at the root, correct
# Content-Type for Android APK installs and iOS OTA manifest plists,
# zstd / gzip compression. No `/downloads/` subpath needed — binaries
# live directly under https://pro.interactpak.com/<filename>.
#
# `bash scripts/build-and-upload.sh` rsyncs straight to /var/www/interactpro/
# matching the existing block. No further Caddy work required.
#
# This file is kept as a stub so existing references in docs / CI don't
# break, and so that if the block is ever removed accidentally we have
# the canonical version on hand.

set -euo pipefail

cat <<'NOTE'
install-pro-caddy.sh is no longer needed.

The pro.interactpak.com Caddy block is already in place on the VPS,
serving /var/www/interactpro/ at the root. To ship binaries:

    bash scripts/build-and-upload.sh

That rsyncs to /var/www/interactpro/ and the existing block does the
rest.

If you ever need to recreate the block from scratch (e.g. a fresh VPS),
the canonical version is in the comment block at the top of this script.
NOTE
NOTE
