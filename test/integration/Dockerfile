FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ufw iproute2 python3 sudo bash ca-certificates bats \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
ENTRYPOINT ["bats", "--tap", "test/integration/killswitch.bats"]
