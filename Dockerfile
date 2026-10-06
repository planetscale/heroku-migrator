FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
# TMPDIR is what Perl/glibc honor on Linux (TMP is the Windows name); Bucardo
# (Perl) needs it set or temp-dir resolution can fail.
ENV TMP=/tmp
ENV TMPDIR=/tmp
ENV BUCARDO_VERSION=5.6.0
ENV PG_MAJOR=18
ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:$PATH"
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

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
      postgresql-${PG_MAJOR} \
      postgresql-plperl-${PG_MAJOR} \
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

# Writable dirs for runtime (Heroku runs as a random non-root UID).
# /tmp must be 1777 (sticky), not 777: Ruby's Dir.tmpdir rejects a non-sticky
# world-writable temp dir, which breaks Dir.mktmpdir.
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

RUN useradd -M -d /opt/bucardo -u 1000 -g 0 bucardo && \
    chown -R bucardo:0 /opt/bucardo /var/run/bucardo /var/log/bucardo
USER bucardo
WORKDIR /opt/bucardo

ENTRYPOINT ["/opt/bucardo/entrypoint.sh"]
