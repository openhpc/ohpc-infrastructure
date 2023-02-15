# OpenHPC OBS worker container

To run OBS workers on something else then Leap we use
a container. Installation details can be found in the
ansible files.

## Build container

```shell
$ podman build . -t openhpc-obs-worker:latest
```

## Push container

``` shell
$ podman push localhost/openhpc-obs-worker:latest quay.io/ohpc/openhpc-obs-worker:latest
```
