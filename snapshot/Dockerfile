# Snapshot restore image: the tools the restore script needs on a plain
# Alpine base, pinned by digest. Built locally by compose and run once,
# by setup.sh, when the chain volumes are empty; never started by `up`.
FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8

RUN apk add --no-cache bash curl jq zstd

COPY restore.sh /usr/local/bin/restore.sh
ENTRYPOINT ["bash", "/usr/local/bin/restore.sh"]
