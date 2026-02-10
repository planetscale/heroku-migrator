FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV TMP=/tmp
ENV BUCARDO_VERSION=5.6.0
ENV PATH="/usr/lib/postgresql/17/bin:$PATH"

# Install PostgreSQL 17 and Bucardo dependencies
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
      postgresql-17 \
      postgresql-plperl-17 \
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
    chmod 777 /var/run/bucardo /var/log/bucardo /opt/bucardo/pgdata /opt/bucardo/state /opt/bucardo /tmp && \
    echo '' > /etc/bucardorc && chmod 666 /etc/bucardorc && \
    chmod 666 /etc/passwd

# Copy scripts
COPY scripts/ /opt/bucardo/scripts/
COPY status-server/ /opt/bucardo/status-server/
COPY entrypoint.sh /opt/bucardo/entrypoint.sh

RUN chmod +x /opt/bucardo/entrypoint.sh /opt/bucardo/scripts/*.sh

EXPOSE ${PORT:-8080}

ENTRYPOINT ["/opt/bucardo/entrypoint.sh"]
