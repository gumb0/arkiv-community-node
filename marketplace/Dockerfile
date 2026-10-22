# The marketplace commands: the TypeScript source on the pinned Node
# image, run as it is; Node strips the types itself, so there is no
# build step. Built locally by compose, never pulled as a tool image.
# The base image is held still by digest.
FROM node:22.23.4-bookworm-slim@sha256:5991875dfb80938dd8a6ba3fe3e96fd04929e70792762b3319d8caadbbe229bc
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY src ./src
COPY addresses.json ./
# The keystore lives in the mounted secrets directory; the node is
# reached over the compose network (see compose.yaml).
ENTRYPOINT ["node", "src/cli.ts"]
