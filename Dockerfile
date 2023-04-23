# syntax=docker/dockerfile:1.4
ARG ALPINE_VERSION
ARG ALPINE_DIGEST

FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.2.1@sha256:39ede8c0cf7329034c114bffdb1d55b8c62daf1374f9d6d44b9463dc03b19b4a AS xx
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION}@sha256:${ALPINE_DIGEST} AS alpine-base

# alpine container with tar
FROM --platform=$BUILDPLATFORM alpine:3.17@sha256:124c7d2707904eea7431fffe91522a01e5a861a624ee31d03372cc1d138a3126 AS get-src
RUN apk add --no-cache tar

# alpine container with packer src at /usr/src/packer
FROM get-src AS get-packer-src
ARG PACKER_SOURCE_HOST PACKER_VERSION
RUN <<eof
  wget -O packer.tar.gz ${PACKER_SOURCE_HOST}/v${PACKER_VERSION}.tar.gz;
  mkdir -p /usr/src/packer;
  tar --extract --directory /usr/src/packer --strip-components=1 --file packer.tar.gz;
  rm packer.tar.gz;
eof

# alpine container with BUILDPLATFORM go binary at /usr/local/go
FROM get-src AS get-go-bin
ARG GO_VERSION
COPY --link --from=xx / /
COPY --link --from=get-packer-src /usr/src/packer/.go-version ./
RUN <<eof
  if [ "$GO_VERSION" = "" ]; then export GO_VERSION=$(echo `cat .go-version`); fi;
  wget -O go.tar.gz https://go.dev/dl/go$GO_VERSION.$(xx-info os)-$(xx-info arch).tar.gz
  tar -C /usr/local -xzf go.tar.gz;
  rm go.tar.gz;
eof

# alpine container with BUILDPLATFORM go binary and go deps
FROM alpine-base as alpine-go-base
ENV CGO_ENABLED=0
ENV GOPATH /go
ENV PATH $GOPATH/bin:/usr/local/go/bin:$PATH
RUN <<eof 
  mkdir -p "$GOPATH/src" "$GOPATH/bin" && chmod -R 1777 "$GOPATH";
  apk add --no-cache libc6-compat;
eof
COPY --link --from=xx / /
COPY --link --from=get-go-bin /usr/local/go /usr/local/go
WORKDIR /usr/src/packer

# go container with packer build deps
FROM alpine-go-base AS alpine-packer-base
COPY --link --from=get-packer-src /usr/src/packer/go.mod /usr/src/packer/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
  --mount=type=cache,target=/root/.cache/go-build \
  go mod download

# go container with TARGETPLATFORM packer built
FROM alpine-go-base AS alpine-packer-build
COPY --link --from=get-packer-src /usr/src/packer /usr/src/packer
ARG TARGETPLATFORM PACKER_LDFLAGS
RUN --mount=type=cache,target=/go/pkg/mod \
  --mount=type=cache,target=/root/.cache/go-build \
  xx-go build -o "/usr/local/bin" -ldflags="$PACKER_LDFLAGS" -trimpath -buildvcs=false

FROM scratch as dist
COPY --from=alpine-packer-build /usr/local/bin/packer /packer

# alpine container with TARGETPLATFORM packer for testing
FROM alpine-base AS alpine-packer-test
ARG TARGETPLATFORM PACKER_VERSION
COPY --link --from=xx / /
COPY --link --from=dist /packer /usr/local/bin/packer
RUN <<eof
  if xx-info is-cross; then echo -e "🧪\t I am $(xx-info march) running from $(TARGETPLATFORM=$BUILDPLATFORM xx-info march)."; fi
  # use xx-verify to check binary
  if xx-verify --static $(which packer); then echo -e "🧪\t xx-verify matches target arch"; else echo -e "⛔️\t xx-verify failed" && exit 1; fi
  # ensure version matches packer version
  _PACKER_VERSION=`$(which packer) --version`
  if [ "$_PACKER_VERSION" = "$(echo $PACKER_VERSION | sed -r 's/(-[a-z0-9]*)$//')" ]; then echo -e "🧪\t packer --version is $_PACKER_VERSION"; else echo -e "⛔️\t packer --version is $_PACKER_VERSION, expected $PACKER_VERSION" && exit 1; fi
eof

# alpine container with TARGETPLATFORM packer for dist
FROM alpine-base AS alpine-release
ARG TARGETPLATFORM
RUN apk add --no-cache git bash wget xorriso
COPY --link --from=dist /packer /usr/local/bin/packer
ENTRYPOINT ["/usr/local/bin/packer"]