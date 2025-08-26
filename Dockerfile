ARG ARCH
ARG ubuntu_version
FROM ubuntu:${ubuntu_version:-24.04}

ENV DEBIAN_FRONTEND=noninteractive

# Install required libraries
RUN apt update && apt -y install \
    curl \
    gnupg2 \
    lsb-release \
    lz4 \
    bzip2 \
    openssh-client

# Install percona xtrabackup 8.0
RUN curl -O https://repo.percona.com/apt/percona-release_latest.generic_all.deb && \
    apt -y install ./percona-release_latest.generic_all.deb && \
    rm -f ./percona-release_latest.generic_all.deb && \
    apt update && \
    percona-release setup pxb-80 && \
    apt -y install percona-xtrabackup-80

ADD ./rootfs /
RUN chmod +x /usr/local/bin/*.sh
