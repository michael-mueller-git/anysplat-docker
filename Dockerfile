# syntax=docker/dockerfile:1
#
# AnySplat web UI (Gradio) - self-hostable container.
#
# Wraps the Hugging Face Space `alexnasa/AnySplat` (feed-forward 3D Gaussian
# Splatting from unconstrained views):
#   - deps installed at build time (no runtime pip)
#   - binds 0.0.0.0:7860, NO auth inside (put auth in front via ingress/proxy)
#   - optional external model cache mirror at runtime (HF_ENDPOINT / HF_HOME)
#
ARG CUDA_VERSION=12.8.1
ARG UBUNTU_VERSION=22.04
# Shared by both stages (re-declared inside each stage to pull the value in).
ARG TORCH_VERSION=2.8.0
# 8.0 = A100/CMP-170HX (sm_80), 8.6 = RTX 3090 (sm_86). Override as needed.
ARG TORCH_CUDA_ARCH_LIST="8.0;8.6"
ARG GSPLAT_VERSION=1.5.3
# Optional build-time Python package mirror, e.g. https://proxpi.k8s.lan/index/
ARG PIP_INDEX_URL=""

# --- gsplat (compiled against the runtime torch ABI) -------------------------
# The Space pins gsplat-1.5.3+pt22cu121, a wheel built for torch 2.2/CUDA 12.1.
# Its _C extension does not load under torch 2.8/CUDA 12.8, so gsplat falls
# back to JIT compilation; the runtime base has no nvcc, so gsplat disables
# itself (_C=None) and every render dies with:
#   AttributeError: 'NoneType' object has no attribute 'CameraModelType'
# Build it from source here and copy the result into the runtime image.
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS gsplat-build
ARG TORCH_VERSION
ARG TORCH_CUDA_ARCH_LIST
ARG GSPLAT_VERSION
ARG PIP_INDEX_URL
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST} \
    PIP_INDEX_URL=${PIP_INDEX_URL:-https://pypi.org/simple}

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        python3.10 python3.10-dev python3-pip python-is-python3 ninja-build \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip "setuptools<81" wheel packaging \
 && python3 -m pip install torch==${TORCH_VERSION} \
      --index-url https://download.pytorch.org/whl/cu128 \
 && MAX_JOBS=4 python3 -m pip install --no-build-isolation --no-deps \
      --no-binary gsplat "gsplat==${GSPLAT_VERSION}"

# --- runtime image ------------------------------------------------------------
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

# Space to vendor (pinned).
ARG SPACE_REPO=alexnasa/AnySplat
ARG SPACE_REV=94ef0326ac30a713906d583ad1fbcfe814c5faf1
ARG TORCH_VERSION
# The Space's README pins `sdk_version`; gradio is NOT in requirements.txt
# (HF Spaces installs it from the SDK), so it must be added explicitly.
ARG GRADIO_VERSION=5.41.1
ARG TORCH_CUDA_ARCH_LIST
ARG PIP_INDEX_URL


ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST} \
    PIP_INDEX_URL=${PIP_INDEX_URL:-https://pypi.org/simple} \
    HF_HOME=/cache/huggingface

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.10 python3.10-dev python3-pip python-is-python3 \
        git curl ca-certificates ffmpeg \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip "setuptools<81" wheel

# --- vendored AnySplat app code (pinned commit) -----------------------------
WORKDIR /app
RUN GIT_LFS_SKIP_SMUDGE=1 git clone https://huggingface.co/spaces/${SPACE_REPO} /app \
 && git -C /app checkout ${SPACE_REV} \
 && rm -rf /app/.git

# The shipped pytorch3d wheel lives in Git LFS: a plain clone yields only a
# 133-byte pointer, so fetch the real artifact from the resolve endpoint.
RUN curl -fL --retry 3 \
      "https://huggingface.co/spaces/${SPACE_REPO}/resolve/${SPACE_REV}/pytorch3d-0.7.9-cp310-cp310-linux_x86_64.whl" \
      -o /app/pytorch3d-0.7.9-cp310-cp310-linux_x86_64.whl \
 && stat -c '%s %n' /app/pytorch3d-0.7.9-cp310-cp310-linux_x86_64.whl \
 && test "$(stat -c%s /app/pytorch3d-0.7.9-cp310-cp310-linux_x86_64.whl)" -gt 1000000

# --- PyTorch (CUDA 12.8 wheels, Python 3.10) --------------------------------
RUN python3 -m pip install \
      torch==${TORCH_VERSION} torchvision torchaudio \
      --index-url https://download.pytorch.org/whl/cu128

# --- pytorch3d (shipped wheel) + gsplat + torch_scatter ---------------------
# gsplat is installed here for its runtime deps (ninja, rich, ...); the wheel's
# _C extension is replaced by the source build from the stage above.
RUN python3 -m pip install /app/pytorch3d-0.7.9-cp310-cp310-linux_x86_64.whl \
 && python3 -m pip install \
      "torch_scatter @ https://data.pyg.org/whl/torch-2.8.0%2Bcu128/torch_scatter-2.1.2%2Bpt28cu128-cp310-cp310-linux_x86_64.whl" \
      "gsplat @ https://github.com/nerfstudio-project/gsplat/releases/download/v1.5.3/gsplat-1.5.3+pt22cu121-cp310-cp310-linux_x86_64.whl"

# --- remaining python deps --------------------------------------------------
# gradio is supplied by the HF Space SDK, not by requirements.txt; install it
# explicitly and prove it imports, so a missing dep fails the build not the pod.
RUN python3 -m pip install -r /app/requirements.txt \
 && python3 -m pip install "gradio==${GRADIO_VERSION}" \
 && python3 -c "import gradio; print('gradio', gradio.__version__)"

# Swap in the extension compiled by the gsplat-build stage; the wheel installed
# via requirements.txt is built for a different torch ABI (see above).
RUN rm -rf /usr/local/lib/python3.10/dist-packages/gsplat
COPY --from=gsplat-build /usr/local/lib/python3.10/dist-packages/gsplat /usr/local/lib/python3.10/dist-packages/gsplat
# Fail the build, not the pod, if the compiled extension cannot be loaded.
RUN python3 -c "from gsplat import csrc; print('gsplat csrc:', csrc.__file__)"

# --- bake the model weights (~2.9 GB) so the image runs fully offline --------
ARG MODEL_REPO=lhjiang/anysplat
ARG MODEL_REV=d2e8c343672646041ad4ea518184968f94362f01
RUN MODEL_REPO=${MODEL_REPO} MODEL_REV=${MODEL_REV} \
    python3 -c "import os; from huggingface_hub import snapshot_download; snapshot_download(os.environ['MODEL_REPO'], revision=os.environ['MODEL_REV'], local_dir='/opt/models/anysplat')" \
 && du -sh /opt/models/anysplat

# --- containerize the app (no runtime pip, bind 0.0.0.0, no HF ZeroGPU/share) -
COPY tools/patch_app.py /app/tools/patch_app.py
RUN python3 /app/tools/patch_app.py /app/app.py

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && mkdir -p /app/proprocess_results /cache/huggingface \
 && chmod -R 0777 /app/proprocess_results /cache/huggingface

EXPOSE 7860
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
