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
- **Input:** video (frames extracted at 1 fps) *or* a set of images — see
  [Frame extraction](#frame-extraction) to control which/how many frames are
  used.
- **Output:** an interactive `.ply` splat plus interpolated RGB + depth videos.

## Image

```
ghcr.io/michael-mueller-git/anysplat-docker:latest
```

Built and pushed by GitHub Actions on every push to `main` (and on `v*` tags).
Base: CUDA 12.8 runtime + Python 3.10, PyTorch 2.8 (cu128), gsplat 1.5.3
(compiled from source for the runtime torch ABI), pytorch3d 0.7.9.

## Run

```bash
docker run --rm --gpus all -p 7860:7860 \
  ghcr.io/michael-mueller-git/anysplat-docker:latest
# open http://localhost:7860
```

## Frame extraction

The **Video** tab samples the clip at a fixed **1 frame per second**
(`frame_interval = int(fps * 1)` in the vendored `extract_frames`), with no UI
control for it. The **Images** tab applies no sampling at all: every uploaded
file becomes one view. So to decide which / how many frames the model sees,
pre-extract them with `ffmpeg` and upload them as images.

The frame count (`K`) drives VRAM and runtime: the model attends over all views
at once, and each is resized to 448x448 internally. Keep `K` around 16-32 on a
small GPU.

### Extract frames for the Images tab

Every frame of the clip:

```bash
mkdir -p frames
ffmpeg -i in.mp4 -vsync 0 frames/%06d.png      # -fps_mode passthrough on ffmpeg >= 6
```

Fixed rate over a time range, at model resolution (smaller upload, same result):

```bash
ffmpeg -ss 0 -t 20 -i in.mp4 -vf "fps=4,scale=448:-2" frames/%06d.png
```

`fps=1/2` = one frame every 2 s. Evenly spaced `N` frames across the whole clip:

```bash
N=24
K=$(ffprobe -v error -select_streams v:0 -count_frames \
      -show_entries stream=nb_read_frames -of csv=p=0 in.mp4)
ffmpeg -i in.mp4 -vf "select='not(mod(n\,$((K/N))))'" -vsync 0 frames/%06d.png
```

(Needs `K >= N`; the zero-padded names keep the upload in temporal order - the
app always sorts the paths.)

### Video tab: re-time a clip so the fixed 1 fps grab keeps more frames

The sampler keeps one frame per second of the uploaded file's timeline, i.e.
every `source_fps`-th frame of a 30 fps clip. Re-time the clip so the frames you
want land on whole seconds, then upload it as usual:

```bash
# every frame of a 30 fps clip: setpts = source fps
ffmpeg -i in.mp4 -vf "setpts=30*PTS" -r 1 every-frame.mp4

# every 3rd frame: setpts = source fps / 3
ffmpeg -i in.mp4 -vf "setpts=10*PTS" -r 1 every-3rd.mp4
```

The result is a genuine 1 fps file: the app then keeps one frame per second of
the slowed timeline, so `setpts = source_fps / spacing` picks one frame every
`spacing` original frames. The UI plays the upload back as a slow slideshow, and
the file must stay at >= 1 fps (`int(fps)` is used as the stride - a sub-1 fps
file makes the app crash with `ZeroDivisionError`). For anything longer than a
quick test, pre-extracting to images is cleaner.

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
default `5.41.1`), `GSPLAT_VERSION` (default `1.5.3`), `TORCH_CUDA_ARCH_LIST`
(default `8.0;8.6` = CMP-170HX/A100 + RTX 3090), `PIP_INDEX_URL` (build-time
package mirror).

## Notes

- **GPU arch:** the build defaults to `sm_80;sm_86`. For another GPU set
  `--build-arg TORCH_CUDA_ARCH_LIST=...`.
- **gsplat:** compiled from source in a CUDA `-devel` stage against the image's
  torch. The Space pins a `+pt22cu121` wheel that cannot load under torch 2.8,
  and the runtime base has no `nvcc` for gsplat's JIT fallback, so a matching
  prebuilt extension must be baked in.
- **Auth:** none in the app by design; terminate auth at your proxy/ingress.
- **Footprint:** the image is large (CUDA + torch + 2.9 GB weights).

## Credits

AnySplat is by the AnySplat authors (MIT). The Gradio UI is the HF Space by
[@alexandernasa](https://twitter.com/alexandernasa/). This repo only packages
them into a container.
