FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV TMP=/tmp
ENV BUCARDO_VERSION=5.6.0
ENV PATH="/usr/lib/postgresql/18/bin:$PATH"
# UTF-8 locale so Perl (Bucardo) and psql don't fall back to ASCII/POSIX
# when handling non-ASCII identifiers and data.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# Install PostgreSQL 18 and Bucardo dependencies. pg_dump refuses to dump a
# server newer than itself, so the client tools must be at least as new as the
# Heroku source; older sources and PlanetScale targets are still supported.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl \
      ca-certificates \
      gnupg \
      lsb-release \
      ruby \
      ruby-webrick \
      ruby-json \
      procps \
    && echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -c -s)-pgdg main" | \
       tee /etc/apt/sources.list.d/pgdg.list && \
    curl -L -S -f -s https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
       gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg --yes && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      libdbd-pg-perl \
      libdbix-safe-perl \
      libpod-parser-perl \
      postgresql-18 \
      postgresql-plperl-18 \
      make \
      perl \
    && rm -rf /var/lib/apt/lists/*

# Install Bucardo from source
RUN curl -L -o /tmp/bucardo-${BUCARDO_VERSION}.tar.gz \
      https://github.com/bucardo/bucardo/archive/${BUCARDO_VERSION}.tar.gz && \
    tar -C /tmp -xf /tmp/bucardo-${BUCARDO_VERSION}.tar.gz && \
    cd /tmp/bucardo-${BUCARDO_VERSION} && \
    perl Makefile.PL && \
    make && \
    make install && \
    rm -rf /tmp/bucardo-*

# Create writable directories for runtime use (Heroku runs as a random non-root UID)
RUN mkdir -p /var/run/bucardo /var/log/bucardo /opt/bucardo/pgdata /opt/bucardo/state && \
    chmod 777 /var/run/bucardo /var/log/bucardo /opt/bucardo/pgdata /opt/bucardo/state /opt/bucardo && \
    chmod 1777 /tmp && \
    echo '' > /etc/bucardorc && chmod 666 /etc/bucardorc && \
    chmod 666 /etc/passwd

# Copy scripts
COPY scripts/ /opt/bucardo/scripts/
COPY status-server/ /opt/bucardo/status-server/
COPY entrypoint.sh /opt/bucardo/entrypoint.sh

RUN chmod +x /opt/bucardo/entrypoint.sh /opt/bucardo/scripts/*.sh

EXPOSE ${PORT:-8080}

# PostgreSQL refuses to run as root, so default to a non-root user for plain
# `docker run`. Heroku still overrides this with a random UID (in group 0),
# which entrypoint.sh registers in /etc/passwd at startup.
RUN useradd -M -d /opt/bucardo -u 1000 -g 0 bucardo && \
    chown -R bucardo:0 /opt/bucardo /var/run/bucardo /var/log/bucardo
USER bucardo
WORKDIR /opt/bucardo

ENTRYPOINT ["/opt/bucardo/entrypoint.sh"]
