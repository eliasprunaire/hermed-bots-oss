# hv-hermes:hd07, hv-hermes plus an sshd for the tunnel lanes of HD-07
# Build: docker build -t hv-hermes:hd07 docs/spike/hd07-instruments
# The base image has no sshd. Only the user hvssh may log in, by public key, and only to forward 127.0.0.1:8642
ARG BASE=hv-hermes:spike
FROM ${BASE}

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server \
    && apt-get clean \
    && mkdir -p /run/sshd \
    && ssh-keygen -A \
    && useradd --create-home --shell /bin/sh hvssh \
    && usermod -p '*' hvssh \
    && install -d -o hvssh -g hvssh -m 0700 /.ssh

COPY sshd-hv.conf /etc/ssh/sshd_config.d/hv.conf
