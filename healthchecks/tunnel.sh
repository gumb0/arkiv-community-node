#!/bin/sh
# Healthy = frpc reports its proxy running, which means it is connected to
# the tunnel server. The container stays up while disconnected (frpc keeps
# retrying), so "Up" alone says nothing — this badge does.
# POSIX sh + busybox wget: the frp image is plain Alpine, no bash or curl.
wget -qO- http://127.0.0.1:7400/api/status | grep -q '"status" *: *"running"'
