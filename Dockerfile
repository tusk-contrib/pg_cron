# syntax=docker/dockerfile:1

# -------------------------------------------------------------------------------------- #
FROM ghcr.io/cloudnative-pg/postgresql:18.7-minimal-trixie AS builder

USER root

# pg_cron isn't published as a CNPG extension image -> PGDG .deb (the PGDG apt repo is
# already configured in the CloudNativePG base image).
# The PGDG build of pg_cron.so links against symbols of the PostgreSQL minor release it
# was compiled with. If installing it would upgrade the server package, the base image is
# older than the package and the resulting .so would fail to load in the operand image,
# so the build fails: bump the base image tag to the latest PostgreSQL minor release.
ARG PG_CRON_VERSION=1.6.8
RUN before="$(dpkg-query -W -f='${Version}' postgresql-18)" \
    && apt-get update \
    && apt-get install -y --no-install-recommends "postgresql-18-cron=${PG_CRON_VERSION}-*" \
    && after="$(dpkg-query -W -f='${Version}' postgresql-18)" \
    && rm -rf /var/lib/apt/lists/* \
    && if [ "${before}" != "${after}" ]; then \
         echo "ERROR: installing pg_cron upgraded postgresql-18 ${before} -> ${after}; bump the base image" >&2; \
         exit 1; \
       fi

# Copy the shared library and extension files into the CloudNativePG image volume layout.
RUN mkdir -p /out/lib /out/share/extension \
    && cp -L /usr/lib/postgresql/18/lib/pg_cron.so /out/lib/ \
    && cp -L /usr/share/postgresql/18/extension/pg_cron* /out/share/extension/ \
    && ls -lR /out

# -------------------------------------------------------------------------------------- #
# Extension-only image (CloudNativePG image volume layout)
FROM scratch AS final

COPY --from=builder /out/ /
