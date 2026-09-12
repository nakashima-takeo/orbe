# Build image for the CLI.
FROM swift:6.0 AS build
WORKDIR /src
COPY . .
RUN swift build -c release --product orbe-cli

FROM debian:bookworm-slim
COPY --from=build /src/.build/release/orbe-cli /usr/local/bin/orb
ENTRYPOINT ["orb"]
