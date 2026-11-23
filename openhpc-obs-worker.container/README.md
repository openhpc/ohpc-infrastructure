# OpenHPC OBS worker container

To run OBS workers on something else then Leap we use
a container. Installation details can be found in the
ansible files.

The image is built for x86_64 and aarch64 by the GitHub workflow
`build-obs-worker-container.yml` once a week and after each change to
this directory. The workflow publishes the image as
`ghcr.io/openhpc/obs-worker:latest` and deletes the image versions of
previous builds.

The container exits with an error if the workers cannot be started or
if no worker process is running anymore. The systemd service on the
worker hosts restarts the container in that case.

## Build container locally

```shell
$ podman build . -t obs-worker:latest
```
