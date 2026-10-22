# Snapshot restore image: the tools the restore script needs on a plain
# Alpine base, pinned by digest. Built locally by compose and run once,
# by setup.sh, when the chain volumes are empty; never started by `up`.
FROM alpine:3.22.7@sha256:e9f2de928efcc1b53d0948e684b4f490315f280de6044844ec0ff26c0b44d3cf

# The CA bundle is upgraded past the base image's: a snapshot host whose
# certificate chain needs a newer root would otherwise fail the download.
RUN apk add --no-cache --upgrade ca-certificates ca-certificates-bundle bash curl jq zstd

COPY restore.sh /usr/local/bin/restore.sh
ENTRYPOINT ["bash", "/usr/local/bin/restore.sh"]
