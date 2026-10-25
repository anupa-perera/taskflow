# Ansible controller, the same image locally (scripts/ansible.sh) and in CI.
ARG BASE_IMAGE=python:3.13-slim-trixie@sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962
FROM ${BASE_IMAGE}

# The aws_ssm connection drives Session Manager through this plugin.
ARG SESSION_MANAGER_PLUGIN_VERSION=1.2.896.0
ADD --checksum=sha256:53f51fcc67314a4bf85888a38a3967cd41f8d0f28a60a9469a63acf935ba713e \
    https://s3.amazonaws.com/session-manager-downloads/plugin/${SESSION_MANAGER_PLUGIN_VERSION}/ubuntu_64bit/session-manager-plugin.deb \
    /tmp/session-manager-plugin.deb
RUN dpkg -i /tmp/session-manager-plugin.deb && rm /tmp/session-manager-plugin.deb

COPY requirements.txt requirements.yml /tmp/
RUN pip install --no-cache-dir --root-user-action=ignore --require-hashes -r /tmp/requirements.txt \
 && ansible-galaxy collection install -r /tmp/requirements.yml -p /usr/share/ansible/collections

RUN useradd --create-home --uid 10001 ansible
USER 10001:10001
WORKDIR /work/ansible
