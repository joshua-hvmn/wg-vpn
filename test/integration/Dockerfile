# The killswitch tests are destructive, so they only run in disposable environments like
# a Docker container or GitHub runner.
FROM ubuntu:24.04
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bats \
        ca-certificates \
        conntrack \
        iproute2 \
        iptables \
        python3 \
        sudo \
        ufw \
        wireguard-tools \
    && rm -rf /var/lib/apt/lists/*

RUN : >/etc/ufw/sysctl.conf \
    && sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw

WORKDIR /repo
ENTRYPOINT ["bats", "--print-output-on-failure"] 
CMD ["test/integration/killswitch.bats"]
