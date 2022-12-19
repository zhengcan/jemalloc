####################
# deps
FROM --platform=amd64 openjdk:11-slim-buster as openjdk
FROM --platform=amd64 dragonwell-registry.cn-hangzhou.cr.aliyuncs.com/dragonwell/dragonwell:11-extended-ga-ubuntu as dragonwell

FROM --platform=amd64 debian:bullseye-slim as select-jdk
COPY --from=openjdk /usr/local/openjdk-11 /opt/java/openjdk
COPY --from=dragonwell /opt/java/openjdk /opt/java/dragonwell

ARG JDK=openjdk
RUN mv /opt/java/${JDK} /opt/java/jdk


####################
# essential
FROM --platform=amd64 debian:bullseye-slim as essential

RUN apt-get update \
  && apt-get install -y --no-install-recommends binutils curl htop procps vim libmysql++3v5 \
  && rm -rf /var/lib/apt/lists/* \
  && rm /bin/sh && ln -s /bin/bash /bin/sh

COPY --from=select-jdk /opt/java/jdk /opt/java/jdk

ENV JAVA_HOME=/opt/java/jdk \
    PATH="/opt/java/jdk/bin:$PATH"

CMD ["/bin/bash"]


####################
# builder
FROM --platform=amd64 essential as builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential bzip2 ca-certificates docker.io git gnupg \
    libmysql++-dev libssl-dev lsb-release pkg-config protobuf-compiler unzip zip \
  && apt-get clean

# SDK Man & Sbt
ENV SDKMAN_DIR=/usr/local/sdkman
ENV SBT_VER=1.6.2
RUN curl -s get.sdkman.io | bash
RUN . "/root/.bashrc" \
  && echo "sdkman_auto_answer=true" > $SDKMAN_DIR/etc/config \
  && echo "sdkman_auto_selfupdate=false" >> $SDKMAN_DIR/etc/config \
  && echo "sdkman_insecure_ssl=false" >> $SDKMAN_DIR/etc/config \
  && echo "sdkman_debug_mode=false" >> $SDKMAN_DIR/etc/config \
  && sdk install sbt $SBT_VER \
  && ln -s $SDKMAN_DIR/candidates/sbt/current/  /opt/sbt \
  && ln -s /opt/sbt/bin/sbt                     /usr/bin/sbt

# FNM, Node, Yarn, PNPM
ENV NODE_VER=18.12.1
ENV PATH=$PATH:/opt/node/bin
RUN cd /opt \
  && curl -fLO https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-x64.tar.xz \
  && tar xvf node-v${NODE_VER}-linux-x64.tar.xz \
  && rm node-v${NODE_VER}-linux-x64.tar.xz \
  && mv node-v${NODE_VER}-linux-x64 node \
  && ln -s /opt/node/bin/corepack /usr/bin/corepack \
  && ln -s /opt/node/bin/node /usr/bin/node \
  && ln -s /opt/node/bin/npm /usr/bin/npm \
  && ln -s /opt/node/bin/npx /usr/bin/npx
RUN npm install -g npm pnpm yarn \
  && ln -s /opt/node/bin/pnpm /usr/bin/pnpm \
  && ln -s /opt/node/bin/pnpx /usr/bin/pnpx \
  && ln -s /opt/node/bin/yarn /usr/bin/yarn \
  && ln -s /opt/node/bin/yarnpkg /usr/bin/yarnpkg
RUN npm config list \
  && yarn config list \
  && pnpm config list

# Rust
ENV PATH=/root/.cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly \
  && cargo --version
RUN cargo install sccache \
  && echo '[build]' >> /root/.cargo/config.toml \
  && echo 'rustc-wrapper = "/root/.cargo/bin/sccache"' >> /root/.cargo/config.toml


####################
# jemalloc & tcmalloc
FROM --platform=amd64 builder as malloc

ENV JEMALLOC_VER=5.3.0
RUN mkdir -p /jemalloc \
  && cd /jemalloc \
  && curl -fLO https://github.com/jemalloc/jemalloc/releases/download/${JEMALLOC_VER}/jemalloc-${JEMALLOC_VER}.tar.bz2 \
  && tar -jxvf jemalloc-${JEMALLOC_VER}.tar.bz2 \
  && cd jemalloc-${JEMALLOC_VER} \
  && ./configure \
  && make -j $(($(nproc) - 2)) \
  && rm -rf /usr/local \
  && mkdir -p /usr/local \
  && make install

RUN apt update \
  && apt install libtcmalloc-minimal4 \
  && mv /usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4 /usr/local/lib/libtcmalloc_minimal.so.4 \
  && ln -s /usr/local/lib/libtcmalloc_minimal.so.4 /usr/local/lib/libtcmalloc_minimal.so \
  && ln -s /usr/local/lib/libtcmalloc_minimal.so.4 /usr/local/lib/libtcmalloc.so


####################
# runtime
FROM --platform=amd64 essential as runtime

ENV JEMALLOC_SO=/usr/local/lib/libjemalloc.so
ENV TCMALLOC_SO=/usr/local/lib/libtcmalloc.so

COPY --from=malloc /usr/local /usr/local

