variable "OS_FLAVOR" { # DF
  default = "alpine"
}
variable "PACKER_VERSION" { # DF
  default = "1.8.6"
}
variable "ALPINE_VERSION" { # DF
  default = "3.17"
}
variable "ALPINE_DIGEST" { # DF
  default = "124c7d2707904eea7431fffe91522a01e5a861a624ee31d03372cc1d138a3126"
}
variable "DEBIAN_VERSION" { # DF
  default = "11.6"
}
variable "GO_VERSION" { # DF
  default = ""
}
variable "PACKER_LD_TAG" { # DF: go
  default = "github.com/hashicorp/packer/version"
}
variable "PACKER_SOURCE_HOST" { # DF: packer source location
  default = "https://github.com/hashicorp/packer/archive/refs/tags"
}
variable "DATE" { # bake: date -u +'%Y-%m-%dT%H:%M:%SZ'
  default = "2023-04-19T20:20:12Z"
}
variable "GIT_HOSTNAME" { # bake: this repositories hostname
  default = "https://github.com"
}
variable "GIT_REPO" { # bake: this repositories user/repo
  default = "trailmix/packer"
}
variable "GIT_SHA" { # bake: this repositories sha
  default = "e82d44ff85f8f3a8ca4bc5896ca08d094bbd20e8"
}
variable "REGISTRIES" { # bake: registry hostnames
  default = ["docker.io"]
}
variable "S3_REGION" { #* bake: s3 region for caching
  default = "us-east-1"
}
variable "S3_BUCKET" { #* bake: s3 bucket for caching
  default = ""
}
variable "S3_BUCKET_PREFIX" { # bake: s3 prefix for caching
  default = ""
}
variable "S3_ENDPOINT" { # bake: s3 endpoint for caching
  default = ""
}
function "tag" {
  params = []
  result = format("%s-%s%s%s",
    PACKER_VERSION,
    OS_FLAVOR,
    ALPINE_VERSION,
    equal(GO_VERSION, "") ? "" : "-${GO_VERSION}"
  )
}
# output: sha[optional length limit]
function "sha" {
  params = [sha]
  result = equal(sha, 0) ? GIT_SHA : regex_replace(GIT_SHA, "([0-9a-fA-F]{${sha},${sha}}).*", "$1")
}
# suffix something to append to tag (string or "")
# NOTE: if "" then will provide base tag
# unique a unique tag (string or "")
# output: list( REGISTRIES[*]/GIT_REPO:tag[-suffix] , [REGISTRIES[*]/GIT_REPO:unique] )
function "mirror" {
  params = [suffix, unique]
  result = flatten([for k, reg in REGISTRIES : formatlist("%s/%s:%s",
    reg,
    GIT_REPO,
    concat([
      format("%s%s", regex_replace(tag(), "/", "-"), equal(suffix, "") ? "" : "-${suffix}")
    ], compact([unique]))
  )])
}
# type (version, prerelease, "")
# version = 1.2.3
# prerelease = dev
# "" = 1.2.3-dev
function "semver" { # pass in "version" or "prerelease" to get full or prerelease, base is default
  params = [type]   # version(1.0.0-dev), base(1.0.0), prerelease(dev)
  result = format("%s",
    regex_replace(    # regex from:
      PACKER_VERSION, # https://semver.org/#is-there-a-suggested-regular-expression-regex-to-check-a-semver-string
      "(?P<major>0|[1-9]d*).(?P<minor>0|[1-9]d*).(?P<patch>0|[1-9]d*)(?:-(?P<prerelease>(?:0|[1-9]d*|d*[a-zA-Z-][0-9a-zA-Z-]*)(?:.(?:0|[1-9]d*|d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\\+(?P<buildmetadata>[0-9a-zA-Z-]+(?:.[0-9a-zA-Z-]+)*))?",
      equal(type, "prerelease") ? "$4" : (equal(type, "version") ? PACKER_VERSION : "$1.$2.$3")
    )
  )
}
# stage (string or "")
# output: GIT_REPO/GIT_SHA[/stage];GIT_REPO/tag()[/stage]
function "cache-tag" {
  params = [stage]
  result = join(";", formatlist("%s/%s%s", GIT_REPO, [sha(7), tag()], format("%s%s", equal(stage, "") ? "" : "/", stage)))
}
# give stage name (string)
# and mode (max,min,"" for none)
# output: type=s3,use_path_style=true,region=S3_REGION,bucket=S3_BUCKET,name=[buildkit|cache-tag(name)][,prefix=S3_BUCKET_PREFIX][,endpoint_url=S3_ENDPOINT][,mode=mode]
function "s3" {
  params = [name, mode]
  result = format("type=s3,use_path_style=%s,region=%s,bucket=%s,name=%s%s%s%s",
    true,                                                             # use_path_style
    S3_REGION,                                                        # pull in region var
    S3_BUCKET,                                                        # bucket
    cache-tag(name),                                                  # name
    equal(S3_BUCKET_PREFIX, "") ? "" : ",prefix=${S3_BUCKET_PREFIX}", # prefix
    equal(S3_ENDPOINT, "") ? "" : ",endpoint_url=${S3_ENDPOINT}",     # endpoint_url
    equal(mode, "") ? "" : ",mode=${mode}"
  )
}
# just returns map of labels
function "labels" {
  params = [labels]
  result = merge({
    "org.opencontainers.image.created"       = "${DATE}"
    "org.opencontainers.image.url"           = "${GIT_HOSTNAME}/${GIT_REPO}/tree/${PACKER_VERSION}"
    "org.opencontainers.image.documentation" = "${GIT_HOSTNAME}/${GIT_REPO}"
    "org.opencontainers.image.source"        = "${GIT_HOSTNAME}/${GIT_REPO}"
    "org.opencontainers.image.version"       = PACKER_VERSION # version from repo
    "org.opencontainers.image.revision"      = sha(0)         # full sha
    "org.opencontainers.image.license"       = "mit"
    "org.opencontainers.image.ref.name"      = tag()
    "org.opencontainers.image.title"         = regex_replace(GIT_REPO, ".*/", "")
    "org.opencontainers.image.description"   = "An alpine:${ALPINE_VERSION} container with packer source from ${PACKER_SOURCE_HOST}/v${PACKER_VERSION}.tar.gz"
    "org.opencontainers.image.base.digest"   = ALPINE_DIGEST
    "org.opencontainers.image.base.name"     = format("docker.io/%s:%s", OS_FLAVOR, ALPINE_VERSION)
  }, labels)
}
# output: list-comma(annotation-index.(LABEL.key)=(LABEL.value))
# pass in var to merge
function "annotations" {
  params = [labels]
  result = join(",", formatlist("annotation-index.%s",
    [for k, v in labels(labels) : format("%s=%s", k, v) if contains([
      "org.opencontainers.image.created",
      "org.opencontainers.image.url",
      "org.opencontainers.image.documentation",
      "org.opencontainers.image.source",
      "org.opencontainers.image.version",
      "org.opencontainers.image.revision",
      "org.opencontainers.image.license",
      "org.opencontainers.image.ref.name",
      "org.opencontainers.image.title",
      "org.opencontainers.image.description",
      "org.opencontainers.image.base.digest",
      "org.opencontainers.image.base.name"
    ], k)]
  ))
}
target "docker-metadata-action" {}
target "all-vars" {
  args = {
    PACKER_VERSION     = PACKER_VERSION
    ALPINE_VERSION     = ALPINE_VERSION
    ALPINE_DIGEST      = ALPINE_DIGEST
    GO_VERSION         = GO_VERSION
    PACKER_SOURCE_HOST = PACKER_SOURCE_HOST
    PACKER_LDFLAGS     = "-X ${PACKER_LD_TAG}.GitCommit=${sha(7)} -X ${PACKER_LD_TAG}.GitDescribe=${semver("")} -X ${PACKER_LD_TAG}.Version=${semver("")} -X ${PACKER_LD_TAG}.VersionPrerelease=${semver("prerelease")} -X ${PACKER_LD_TAG}.VersionMetadata="
  }
  cache-to   = [s3("", "max")]
  cache-from = [s3("", "")]
}
target "all-arch" {
  platforms = [
    "linux/amd64",
    "linux/arm64",
    # "linux/arm/v6",
    # "linux/arm/v7",
    # "linux/s390x",
    # "linux/ppc64le",
  ]
}
group "src" {
  targets = ["get-packer-src", "get-go-bin"]
}
target "get-packer-src" {
  inherits = ["all-vars"]
  target   = "get-packer-src"
}
target "get-go-bin" {
  inherits = ["all-vars"]
  target   = "get-go-bin"
}

target "base" {
  inherits = ["all-vars"]
  target   = "alpine-packer-base"
}
target "build" {
  inherits = ["all-vars", "all-arch"]
  target   = "alpine-packer-build"
}
target "dist" {
  inherits = ["build"]
  target   = "dist"
  output   = ["type=local,dest=dist/"]
}
group "test" {
  targets = ["alpine-packer-test"]
}
target "alpine-packer-test" {
  inherits = ["all-vars", "all-arch"]
  target   = "alpine-packer-test"
}

group "default" {
  targets = ["release", "test"]
}
target "release" {
  inherits = ["all-vars", "all-arch", "docker-metadata-action"]
  attest = [
    "type=sbom,enabled=true",
    "type=provenance,mode=max"
  ]
  target = "alpine-release"
  labels = labels({
    "org.opencontainers.image.description" = join("",
      ["An alpine:${ALPINE_VERSION} container with packer:${PACKER_VERSION}(${PACKER_SOURCE_HOST}/v${PACKER_VERSION}.tar.gz)",
    equal(GO_VERSION, "") ? "." : " built with golang:${GO_VERSION}-alpine${ALPINE_VERSION}."])
  })
  output = ["type=image,${annotations({
    "org.opencontainers.image.description" = join("",
      ["An alpine:${ALPINE_VERSION} container with packer:${PACKER_VERSION}(${PACKER_SOURCE_HOST}/v${PACKER_VERSION}.tar.gz)",
    equal(GO_VERSION, "") ? "." : " built with golang:${GO_VERSION}-alpine${ALPINE_VERSION}."])
  })}"]
}
