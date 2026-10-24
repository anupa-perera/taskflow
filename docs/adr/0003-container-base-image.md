# 0003. Container base image: distroless Node on Debian 13

- Status: Accepted
- Date: 2026-10-24

## Context

The brief asks for a production-quality Dockerfile with a multi-stage build, a non-root user and a
minimal base image, and the pipeline scans the image with Trivy, failing on HIGH or CRITICAL
findings. The same image runs the API and the one-off migration task on ECS on EC2.

Candidate runtime images, measured on 2026-10-24 (compressed linux/amd64 size; Trivy 0.76.1 OS
package findings):

| Image                                         | Size   | OS packages | CRITICAL / HIGH / MEDIUM | Shell | Package manager | Default user |
| --------------------------------------------- | ------ | ----------- | ------------------------ | ----- | --------------- | ------------ |
| `node:24`                                     | 410 MB | 413         | 21 / 612 / 2067          | yes   | apt             | root         |
| `node:24-trixie-slim`                         | 83 MB  | 79          | 0 / 43 / 58              | yes   | apt             | root         |
| `node:24-alpine`                              | 62 MB  | 19          | 0 / 0 / 0                | yes   | apk             | root         |
| `gcr.io/distroless/nodejs24-debian13:nonroot` | 55 MB  | 14          | 0 / 0 / 23               | no    | none            | uid 65532    |

Alpine's lower MEDIUM count is partly methodological: Alpine's security database mostly records
fixed vulnerabilities, while Debian's also tracks unfixed and "won't fix" ones.

## Decision

- **Runtime:** `gcr.io/distroless/nodejs24-debian13:nonroot`, pinned by digest.
- **Build stages:** `node:24-trixie-slim`, pinned by digest. It matches the runtime's Debian 13 and
  glibc, so `node_modules` copied between stages stays binary-compatible.
- The runtime image contains only `dist/`, production `node_modules`, `package.json` and the RDS CA
  bundle (downloaded with a pinned checksum).
- The container health check is a small Node script (`dist/healthcheck.js`), since there is no shell
  or curl.

## Consequences

- Smallest attack surface after a compromise: an attacker who achieves code execution gets no shell
  and no package manager to fetch tools with. Non-root is the image default, not a line that can be
  deleted.
- Build-stage tooling and its HIGH findings never reach the shipped image.
- No shell inside the container: on-call debugging uses the EC2 host (SSM), `docker logs` and
  `docker inspect`, and a toolbox container joined to the task's network namespace (see the runbook).
- Trivy does not detect the Node runtime in this image, because Node is a plain binary rather than
  an OS package. The pipeline therefore checks the image's Node version against Node.js security
  releases separately.
- Pinned digests do not update themselves; they are refreshed deliberately to pick up OS and Node
  patches. The pinned CA checksum fails uncached builds when AWS rotates the bundle, which is
  intended.
