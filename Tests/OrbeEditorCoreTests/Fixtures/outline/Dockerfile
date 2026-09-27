# syntax=docker/dockerfile:1
# check=skip=JSONArgsRecommended
ARG SWIFT_VERSION=6.0

FROM swift:${SWIFT_VERSION} AS build
WORKDIR /src
COPY Package.swift ./
RUN swift package resolve \
    && echo resolved
COPY . .
run swift build -c release

# escape=` is only a directive at the top
FROM ubuntu:24.04
LABEL org.opencontainers.image.title="orbe"
ENV PATH=/app/bin:$PATH \
    LANG=C.UTF-8
COPY --from=build /src/.build/release/orbe /app/bin/
ONBUILD RUN echo child
HEALTHCHECK --interval=30s CMD curl -f http://localhost/ || exit 1
EXPOSE 8080
USER app
ENTRYPOINT ["orbe"]
CMD ["--help"]
