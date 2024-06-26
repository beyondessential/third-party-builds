FROM rust AS builder
ARG MSUPPLY_REF=develop
RUN apt update && apt install -y make gcc pkg-config libavahi-compat-libdnssd-dev libpq-dev

RUN git clone --branch $MSUPPLY_REF --depth 1 https://github.com/msupply-foundation/open-msupply /src
WORKDIR /src/server
RUN cargo build --release --bin remote_server --no-default-features --features postgres

FROM debian
RUN apt update && apt install -y libavahi-compat-libdnssd-dev libpq-dev
COPY --from=builder /src/server/target/release/remote_server /usr/bin/remote_server

RUN useradd --system --create-home --user-group msupply
USER msupply
WORKDIR /home/msupply

COPY --from=builder --chown=msupply:msupply /src/server/data ./data
COPY --from=builder --chown=msupply:msupply /src/server/configuration ./configuration
RUN cd data/reference1 \
  && mv users.txt ../../configuration/users.txt \
  && ln -snf ../../configuration/users.txt

ENTRYPOINT [ "/usr/bin/remote_server" ]
