# Strata as a Podman pod (`podman kube play`)

The same setup as `docker/compose`, written as Kubernetes YAML: one ConfigMap with the settings, one Pod, one
volume. Start it with `podman kube play`, watch it with `podman pod logs`, stop it with `podman kube down`. A
Quadlet unit starts it at boot.

There are no variables in Kubernetes YAML and `podman kube play` takes no `--env-file` (the requests to add one
are open: [containers/podman #26170](https://github.com/containers/podman/issues/26170),
[#24345](https://github.com/containers/podman/issues/24345)), so the settings are written in a file of their own,
`strata-config.yaml`, and the pod finds it by name. One settings file serves all three cards; the pod file is per
card, because the image and the way the card is opened cannot be shared.

## Start

```sh
cp docker/podman/strata-config.yaml ~/strata-config.yaml
cp docker/podman/strata-amd.yaml ~/strata-amd.yaml          # or strata-nvidia.yaml, strata-intel.yaml
podman kube play --configmap ~/strata-config.yaml ~/strata-amd.yaml
podman pod logs strata          # the first start downloads the model (tens of GB, a stopped download continues)
podman kube down ~/strata-amd.yaml        # keeps the volume and the model; --force deletes them
```

The server is at `127.0.0.1:8080` (OpenAI-compatible `/v1/chat/completions`, Anthropic-compatible `/v1/messages`,
a web page at `/`). The address and the port are set when you start it, not in the settings file.

## Address and port

The pod file publishes `127.0.0.1:8080`. To publish on another port or address, add `--publish` to the start
command. Its format is `[[ip:][hostPort]:]containerPort[/protocol]`, and the ports in the file and on the command
line are merged by `containerPort`: the command line wins over the file.

```sh
podman kube play --publish=127.0.0.1:9090:8080 --configmap ~/strata-config.yaml ~/strata-amd.yaml
```

For other computers, `--publish=0.0.0.0:8080:8080`, and keep a real key. In the Quadlet unit the same line is
`PublishPort=127.0.0.1:9090:8080` in `[Kube]`.

The port the server listens on inside the container is 8080, the image's default. It is not a setting in
`strata-config.yaml`, because `containerPort` in the pod file is the match `--publish` uses: if you change one,
you must change the other.

## The settings

`strata-config.yaml` is the file you edit. The names are the same as `docker/compose/.env.example` and
`docs/DOCKER.md`: `MODEL`, `FAMILY`, `MODEL_PATH`, `CONTEXT`, `PARALLEL`, `VISION`, `KV`, `GPUS`, `GPU_ROLES`,
`TUNE`, `API_KEY`, `PRESET`, `STRATA_SET`. A setting with a default is written with that default; a setting
Strata leaves empty is written empty, with an example in the comment.

`PRESET` is `podman` here, not `docker`, so a Docker setup and a Podman setup on the same machine do not share a
preset, a tuning or a key. Show the key Strata made: `podman exec strata-amd strata launch --show-key --preset
podman`. Podman names the running container `<pod name>-<container name>`: the pod is `strata` (metadata.name) and
the container is `amd`, so the name is `strata-amd`. On Podman 5.7 or newer, `--no-pod-prefix` makes it `amd`.

```sh
podman kube play --replace --configmap ~/strata-config.yaml ~/strata-amd.yaml
```

`--replace` applies the change; the model and your preset stay in the volume, so nothing is downloaded again.

Pass `--configmap` every time. The pod reads the settings by name (`envFrom: configMapRef: strata-config`), and
with `optional: true` a ConfigMap that is not there is skipped without an error, so the container starts with the
image's defaults. The file you pass can be named anything; the name inside it must be `strata-config`.

`API_KEY` is a normal setting here, so it goes in this file. It is plain text, exactly as a Kubernetes Secret's
`stringData` is plain text; a Secret adds nothing that `--configmap` cannot carry.

## Files

| File | What it is |
| --- | --- |
| `strata-config.yaml` | the settings, one file for every card |
| `strata-nvidia.yaml` | the pod for an NVIDIA card (RTX 20 to 50; 0.2.3-cuda12 for a GTX 10 card or a driver 575-579) |
| `strata-amd.yaml` | the pod for an AMD card (RX 9000; 0.2.3-rocm-gfx110x for RX 7000, 0.2.3-rocm-gfx1151 for Ryzen AI Max) |
| `strata-intel.yaml` | the pod for an Intel Arc card (A-series, B-series, Arc Pro B70) |
| `strata.kube` | the Quadlet unit for boot |

## At boot (Quadlet)

`strata.kube` is the unit. Put it in `~/.config/systemd/user/` (rootless) or `/etc/systemd/system/` (rootful),
with the full paths to your two files, then `systemctl --user daemon-reload && systemctl --user start strata`:

```ini
[Kube]
Yaml=/home/you/strata-amd.yaml
ConfigMap=/home/you/strata-config.yaml
```

Quadlet runs `podman kube play --replace --service-container=true` on start and `podman kube down` on stop, and
passes `ConfigMap=` as `--configmap`.
`TimeoutStopSec=120s` is the systemd timer for the pod's two-minute drain; `KubeDownForce` is left off, because
deleting the volume on stop deletes the model with it.

## What each compose line became

| `docker/compose` | this file |
| --- | --- |
| `env_file: .env` | `podman kube play --configmap strata-config.yaml`, read by `envFrom: configMapRef` |
| `image` | `containers[].image` |
| `ports: "127.0.0.1:8080:8080"` | `ports[]` with `hostIP: 127.0.0.1`, `hostPort: 8080`, `containerPort: 8080` (Podman publishes only ports with `hostPort`); override it with `--publish=[ip:]hostPort:8080` |
| `volumes: strata-data:/data` | `PersistentVolumeClaim: strata-data` → a Podman volume, kept by `kube down` |
| `shm_size: 2gb` | `emptyDir` with `medium: Memory`, `sizeLimit: 2Gi` (Podman makes a tmpfs of that size) |
| `devices: /dev/dri` | `hostPath` volume + `volumeMounts` + `limits: 'podman.io/device=/dev/dri': 1` (Podman walks the folder and adds every device node inside it) |
| `devices: /dev/kfd` | the same, with `type: CharDevice` |
| `--gpus all` | `limits: 'nvidia.com/gpu=all': 1` (CDI; needs `/etc/cdi/nvidia.yaml` on the host) |
| `security_opt: label=disable` | `seLinuxOptions: type: spc_t` |
| `privileged: true` | `securityContext.privileged: true` |
| `ulimits: memlock: -1` | `io.podman.annotations.ulimit: memlock=-1:-1` (no kube field for ulimits) |
| `stop_grace_period: 2m` | `terminationGracePeriodSeconds: 120` + `TimeoutStopSec=120s` in the Quadlet unit |
| `restart: unless-stopped` | `restartPolicy: Always` (Podman restarts the container, not the pod) |
| `cpus: 4` | `requests.cpu: "4"` — not applied by Podman; `limits.cpu` is applied as a cgroup quota, which throttles generation, so no CPU limit is set |
| `group_add: video, render` | `supplementalGroups`, numbers only (`getent group video render`) |
| `user: 1000:1000` | `user:` in the Quadlet unit, `UserNS=keep-id` |
| `healthcheck` | `livenessProbe` with the image's command and timings (Podman has no `readinessProbe`) |

## What Podman does not support

`readinessProbe`, `startupProbe`, `resources.limits.memory` as a cgroup limit, `resources.requests.cpu`,
`initContainers`, `resources` claims, `configMap` volumes, `secret` volumes, `hostNetwork`, `hostPID`,
`hostPath` with `type: BlockDevice`, `ephemeral` volumes, `projected` volumes, `secrets` as environment from
`envFrom` with `secretRef` (the key is a setting here, so this does not matter).

## Rootless, SELinux

Rootless Podman runs the pod in a user namespace, so the container's root is your user. `UserNS=keep-id` in the
Quadlet unit makes the ids match. The volume's owner is set with `volume.podman.io/uid` and `volume.podman.io/gid`
annotations on the claim. A container that runs as a non-root `user:` needs the render group as a number
(`getent group render | cut -d: -f3`) in `supplementalGroups`; names are not taken.

On SELinux, `spc_t` is the label `--security-opt=label=disable` gives: the container reads the device files it is
given without `setsebool -P container_use_devices` and without relabeling them. The AMD file uses `privileged:
true`, the widest opening, because that is what opens the device cgroup for `/dev/kfd`; the Intel file uses the
smaller opening (no privilege escalation, capabilities dropped except `CAP_DAC_OVERRIDE`). Put the pod on a machine
you control.

> **Not tested on hardware.** The files parse with PyYAML, every field they use is in Podman's `kube play` support
> matrix (checked against Podman 5.8.4's documentation), the settings and the health check match
> `docker/entrypoint.sh`, `docker/healthcheck.sh` and `docs/DOCKER.md`, and
> `tests/terminal/test_docker_files.py` checks all of that on every run. Nothing has been run on a machine with a
> graphics card, and Podman cannot create containers in the environment where these files were written (its
> namespace setup is blocked there). The first run on real hardware is the test.
