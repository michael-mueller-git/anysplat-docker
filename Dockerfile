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
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

# Space to vendor (pinned) and CUDA archs to compile for.
# 8.0 = A100/CMP-170HX (sm_80), 8.6 = RTX 3090 (sm_86). Override as needed.
ARG SPACE_REPO=alexnasa/AnySplat
ARG SPACE_REV=94ef0326ac30a713906d583ad1fbcfe814c5faf1
ARG TORCH_VERSION=2.8.0
ARG TORCH_CUDA_ARCH_LIST="8.0;8.6"
# Optional build-time Python package mirror, e.g. https://proxpi.k8s.lan/index/
ARG PIP_INDEX_URL=""

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
RUN git clone https://huggingface.co/spaces/${SPACE_REPO} /app \
 && git -C /app checkout ${SPACE_REV} \
 && rm -rf /app/.git

# --- PyTorch (CUDA 12.8 wheels, Python 3.10) --------------------------------
RUN python3 -m pip install \
      torch==${TORCH_VERSION} torchvision torchaudio \
      --index-url https://download.pytorch.org/whl/cu128

# --- pytorch3d (shipped wheel) + gsplat + torch_scatter ---------------------
RUN python3 -m pip install /app/pytorch3d-0.7.9-cp310-cp310-linux_x86_64.whl \
 && python3 -m pip install \
      "torch_scatter @ https://data.pyg.org/whl/torch-2.8.0%2Bcu128/torch_scatter-2.1.2%2Bpt28cu128-cp310-cp310-linux_x86_64.whl" \
      "gsplat @ https://github.com/nerfstudio-project/gsplat/releases/download/v1.5.3/gsplat-1.5.3+pt22cu121-cp310-cp310-linux_x86_64.whl"

# --- remaining python deps --------------------------------------------------
RUN python3 -m pip install -r /app/requirements.txt

# --- bake the model weights (~2.9 GB) so the image runs fully offline --------
ARG MODEL_REPO=lhjiang/anysplat
ARG MODEL_REV=d2e8c343672646041ad4ea518184968f94362f01
# Optional HF mirror at build time, e.g. https://olah.k8s.lan
ARG HF_ENDPOINT=""
RUN MODEL_REPO=${MODEL_REPO} MODEL_REV=${MODEL_REV} HF_ENDPOINT=${HF_ENDPOINT} \
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
