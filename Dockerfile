FROM ubuntu:22.04

# Register the ROCM package repository, and install rocm-dev package
ENV HSA_OVERRIDE_GFX_VERSION=11.0.0
ARG ROCM_TARGET=gfx1100
ARG ROCM_VERSION=5.7.2
ARG AMDGPU_VERSION=5.7.2

COPY 90-rocm-pin /etc/apt/preferences.d/rocm-pin-600
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -sL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/rocm.gpg \
    && echo "deb [arch=amd64] https://repo.radeon.com/rocm/apt/$ROCM_VERSION jammy main" | tee /etc/apt/sources.list.d/rocm.list \
    && echo "deb [arch=amd64] https://repo.radeon.com/amdgpu/$AMDGPU_VERSION/ubuntu jammy main" | tee /etc/apt/sources.list.d/amdgpu.list \
    && DEBIAN_FRONTEND=noninteractive apt-get --purge -y autoremove \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends  \
    build-essential rocm-dev rocm-libs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install python and git
ARG PYTHON_VERSION=python3.11
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ${PYTHON_VERSION} ${PYTHON_VERSION}-venv ${PYTHON_VERSION}-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Setup virtual environment
ENV VIRTUAL_ENV=/opt/venv
RUN ${PYTHON_VERSION} -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Compile and install bitsandbytes for ROCm
RUN git clone https://github.com/sremes/bitsandbytes-rocm.git && \
    cd bitsandbytes-rocm && \
    ROCM_HOME=/opt/rocm ROCM_TARGET=${ROCM_TARGET} make hip && \
    pip install .

# Install pytorch (nightly) and transformers+peft, etc.
RUN pip install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/rocm5.7 && rm -rf /root/.cache

ENV PATH="$HOME/.cargo/bin:$PATH"
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y \
    && . "$HOME/.cargo/env" \
    && cd /opt && git clone https://github.com/huggingface/tokenizers \
    && cd tokenizers/bindings/python \
    && pip install . && rm -rf /root/.cache

RUN pip install git+https://github.com/huggingface/transformers \
    git+https://github.com/huggingface/peft \
    git+https://github.com/huggingface/accelerate.git \
    git+https://github.com/huggingface/datasets.git \
    git+https://github.com/huggingface/diffusers.git \
    git+https://github.com/Lightning-AI/lightning.git \
    scipy tensorboard pandas ipython \
    && rm -rf /root/.cache

WORKDIR /app
CMD [ "/bin/bash", "-l" ]
