# Podplane <https://podplane.dev>
# Copyright 2026 Nadrama Pty Ltd
# SPDX-License-Identifier: Apache-2.0
#
# Minimal Debian 13 image used to exercise install.sh (and transitively
# permissions.sh) in isolation. Intentionally NOT a systemd image — install.sh
# disables service starts via policy-rc.d and never invokes systemctl.
#
# All other packages (uidmap, libsubid5, libpq5, fluent-bit, etc.) are
# installed by install.sh itself from the staged deb files in /opt/podplane/deps.

FROM debian:13-slim

# Two groups of packages installed here:
#
#   1. jq, ca-certificates — required by install.sh itself.
#
#   2. libcurl4t64, libsasl2-2, libyaml-0-2 (transitive deps of fluent-bit)
#      and libgssapi-krb5-2, libldap2 (transitive deps of libpq5).
#      The deps manifest deliberately does NOT ship these because the
#      Debian 13 cloud image (the real VM target) already has them; the
#      slim base image we test against does not. Installing them here
#      mirrors that assumption so `dpkg -i` in install.sh can complete
#      configuration of the bundled debs.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      jq ca-certificates \
      libcurl4t64 libsasl2-2 libyaml-0-2 \
      libgssapi-krb5-2 libldap2 \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
