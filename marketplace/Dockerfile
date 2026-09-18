# The marketplace commands: the TypeScript source on the pinned Node
# image, run as it is; Node strips the types itself, so there is no
# build step. Built locally by compose, never pulled as a tool image.
# The base image is held still by digest.
FROM node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY src ./src
COPY addresses.json ./
# The keystore lives in the mounted secrets directory; the node is
# reached over the compose network (see compose.yaml).
ENTRYPOINT ["node", "src/cli.ts"]
