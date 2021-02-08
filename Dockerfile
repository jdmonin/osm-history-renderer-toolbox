# OSM History Render toolbox Docker build.
# See Readme.md and LICENSE.
# Copyirght (C) 2021 Jeremy D Monin.

# Stage 1: clean env to get the osm-history-renderer source and compile its importer;
# uses same postgresql extra repo as stage 2 image Overv/openstreetmap-tile-server Dockerfile to get same libgeos version;
# produces /build/built-renderer.tgz

FROM ubuntu:18.04 AS build-importer
ENV DEBIAN_FRONTEND noninteractive
RUN apt update -qq -y \
  && apt-get install -qq -y --no-install-recommends wget gnupg2 apt-transport-https ca-certificates \
  && wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
  && echo "deb [ trusted=yes ] https://apt.postgresql.org/pub/repos/apt/ bionic-pgdg main" | tee /etc/apt/sources.list.d/pgdg.list \
  && apt-get update -qq -y \
  && apt-get install -qq -y --no-install-recommends \
    libgeos-dev libgeos++-dev libsparsehash-dev libboost-dev libproj-dev libosmpbf-dev libexpat1 libexpat1-dev libpq-dev \
    git make unzip clang-8 \
  && update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-8 100 \
  && update-alternatives --install /usr/bin/clang clang /usr/bin/clang-8 100
WORKDIR /build
# Since ubuntu:18.04 doesn't package v0 of the header-only libosmium,
# get a copy of its recent source, including geos-update commit 60ef244 for lib compat.
# For osm-history-renderer and its importer, use known-good recent commit.
RUN git clone https://github.com/joto/osmium \
  && cd osmium && git checkout 60ef244 \
  && mv include/osmium.hpp include/osmium/ /usr/include/ \
  && cd /build && git clone https://github.com/jdmonin/osm-history-renderer \
  && cd osm-history-renderer && git checkout d6ce421 \
  && cd importer && make \
  && cd /build && /bin/rm -rf osm-history-renderer/.git && tar czf built-renderer.tgz osm-history-renderer

# Stage 2: Final image makes use of OSM's postgis, osmium tool, and carto renderer
# https://github.com/Overv/openstreetmap-tile-server , https://hub.docker.com/r/overv/openstreetmap-tile-server

FROM overv/openstreetmap-tile-server:1.5.0

RUN apt update -qq -y \
  && apt-get install -qq -y --no-install-recommends \
    libprotobuf-lite10 libprotobuf10 python-psycopg2 python-mapnik python-dateutil graphicsmagick gsfonts

WORKDIR /build
COPY --from=build-importer /build/built-renderer.tgz /build/
RUN tar xzf /build/built-renderer.tgz \
  && echo "Cmnd_Alias PGCOMMANDS=/usr/bin/psql, /usr/bin/createdb, /usr/bin/createuser" >> /etc/sudoers \
  && echo "renderer ALL=(postgres) NOPASSWD: PGCOMMANDS" >> /etc/sudoers \
  && mkdir /datasets && chown renderer:renderer /datasets \
  && sed 's/planet_osm/hist_view/g' /home/renderer/src/openstreetmap-carto/mapnik.xml > /home/renderer/src/openstreetmap-carto/mapnik-hist.xml

WORKDIR /datasets

ENTRYPOINT ["/bin/bash"]
RUN []

EXPOSE 5432
