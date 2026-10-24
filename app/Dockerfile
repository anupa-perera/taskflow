# syntax=docker/dockerfile:1

# Digests pin exact images; refresh them deliberately to pick up OS and Node patches.
# Build stages match the runtime's Debian 13 / glibc so copied node_modules stay compatible.
ARG BUILD_IMAGE=node:24-trixie-slim@sha256:43b9ba1142b8dcf33fa8f922ca1be85714adc444e0586c7cf7726daaeabc1bea
ARG RUNTIME_IMAGE=gcr.io/distroless/nodejs24-debian13:nonroot@sha256:cb606325b7ec4af55462cb0b424a53b452a5b4a894ffe841fcf1048d216fb9f8

FROM ${BUILD_IMAGE} AS base
WORKDIR /app
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable
COPY package.json yarn.lock .yarnrc.yml ./

FROM base AS build
RUN yarn install --immutable
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN yarn build

FROM base AS prod-deps
RUN yarn workspaces focus --production

FROM ${RUNTIME_IMAGE}
# Documents the app's default PORT; ECS maps whatever PORT the task definition sets.
ARG APP_PORT=3000
WORKDIR /app
# Public CA bundle for verifying RDS TLS; the checksum fails the build if AWS rotates it.
# Remote ADD defaults to root-only 0600; the app runs as uid 65532 and must read it.
ADD --chmod=0644 --checksum=sha256:90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b \
    https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/rds-global-bundle.pem
ENV DB_SSL_CA_FILE=/app/rds-global-bundle.pem
COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
EXPOSE ${APP_PORT}
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD ["/nodejs/bin/node", "dist/healthcheck.js"]
# The base image's entrypoint is node, which runs as PID 1 and receives SIGTERM directly.
# The migration task overrides this with ["dist/migrate.js"].
CMD ["dist/server.js"]
