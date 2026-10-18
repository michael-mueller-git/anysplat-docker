# anysplat-docker

A self-hostable **AnySplat** web UI: turn a set of uncalibrated images — or a
short video — into a 3D Gaussian Splat in **seconds**, entirely on your own GPU.

This image wraps the Hugging Face Space
[`alexnasa/AnySplat`](https://huggingface.co/spaces/alexnasa/AnySplat) (a Gradio
front-end for [`InternRobotics/AnySplat`](https://github.com/InternRobotics/AnySplat),
feed-forward 3DGS from unconstrained views) so it runs as a plain container.

- **Weights are baked in** — `lhjiang/anysplat` (~2.9 GB) is downloaded at build
  time into `/opt/models/anysplat`, so the container starts offline.
- **No auth inside.** Put authentication in front (ingress / reverse proxy).
- **Input:** video (frames extracted at 1 fps) *or* a set of images.
- **Output:** an interactive `.ply` splat plus interpolated RGB + depth videos.

## Image

```
ghcr.io/michael-mueller-git/anysplat-docker:latest
```

Built and pushed by GitHub Actions on every push to `main` (and on `v*` tags).
Base: CUDA 12.8 runtime + Python 3.10, PyTorch 2.8 (cu128), gsplat 1.5.3,
pytorch3d 0.7.9.

## Run

```bash
docker run --rm --gpus all -p 7860:7860 \
  ghcr.io/michael-mueller-git/anysplat-docker:latest
# open http://localhost:7860
```

## Configuration (runtime, all optional)

| Env | Default | Purpose |
|---|---|---|
| `ANYSPLAT_MODEL` | `/opt/models/anysplat` | model dir or HF repo id (e.g. `lhjiang/anysplat`) |
| `ANYSPLAT_PROCESSED` | `/app/proprocess_results` | uploads + outputs (mount a volume to persist) |
| `GRADIO_SERVER_NAME` / `GRADIO_SERVER_PORT` | `0.0.0.0` / `7860` | listen address/port |
| `GRADIO_ROOT_PATH` | *(unset)* | set if served under a URL sub-path |
| `HF_ENDPOINT` | *(unset)* | external HF cache mirror, e.g. `https://olah.k8s.lan` |
| `HF_HOME` | `/cache/huggingface` | HF cache (only used if a non-baked model is fetched) |
| `HF_TOKEN` | *(unset)* | token for gated/private model mirrors |

## Build args (optional)

`SPACE_REPO`, `SPACE_REV` (vendored Space, pinned), `MODEL_REPO`, `MODEL_REV`
(baked weights, pinned), `GRADIO_VERSION` (must match the Space's `sdk_version`,
default `5.41.1`), `TORCH_CUDA_ARCH_LIST` (default `8.0;8.6` =
CMP-170HX/A100 + RTX 3090), `PIP_INDEX_URL` (build-time package mirror).

## Notes

- **GPU arch:** the build defaults to `sm_80;sm_86`. For another GPU set
  `--build-arg TORCH_CUDA_ARCH_LIST=...`.
- **Auth:** none in the app by design; terminate auth at your proxy/ingress.
- **Footprint:** the image is large (CUDA + torch + 2.9 GB weights).

## Credits

AnySplat is by the AnySplat authors (MIT). The Gradio UI is the HF Space by
[@alexandernasa](https://twitter.com/alexandernasa/). This repo only packages
them into a container.
