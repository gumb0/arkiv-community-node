# Watchdog image: the docker CLI on a pinned Alpine base; the script
# beside this file is the whole program. Built locally by compose.
FROM alpine:3.22

RUN apk add --no-cache docker-cli

COPY watchdog.sh /usr/local/bin/watchdog.sh

ENTRYPOINT ["sh", "/usr/local/bin/watchdog.sh"]
