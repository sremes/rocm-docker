FROM ubuntu:22.04

# Register the ROCM package repository, and install rocm-dev package
ARG ROCM_VERSION=6.0
ARG AMDGPU_VERSION=6.0

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
SHELL ["/bin/bash", "-c"]
ENV VIRTUAL_ENV=/opt/venv
RUN ${PYTHON_VERSION} -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip install -U pip

# Install pytorch (nightly) - remove supplied rocm libraries and force torch and triton to use system versions
RUN pip install --no-cache-dir --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/rocm5.7 \
    && rm -rf /opt/venv/lib/${PYTHON_VERSION}/site-packages/torch/lib/{libMIOpen.so,libamd*,libdrm*,libhip*,libhsa-runtime64.so,libr*,rocblas,libelf.so,libgomp.so,libnuma.so} \
    && rm -rf /opt/venv/lib/${PYTHON_VERSION}/site-packages/triton/third_party/hip/lib/{libamd*,libdrm*,libhsa-runtime64.so,libnuma.so,libelf.so} \
    && ln -sf /opt/rocm/hip/lib/libamdhip64.so /opt/venv/lib/${PYTHON_VERSION}/site-packages/triton/third_party/hip/lib/ \
    && ln -sf /usr/lib/x86_64-linux-gnu/libgomp.so.1 /opt/venv/lib/${PYTHON_VERSION}/site-packages/torch/lib/libgomp.so

# Select and enforce the ROCm gfx version
ENV HSA_OVERRIDE_GFX_VERSION=11.0.0
ARG ROCM_TARGET=gfx1101

# Compile and install bitsandbytes for ROCm
RUN git clone https://github.com/sremes/bitsandbytes-rocm.git && \
    cd bitsandbytes-rocm && \
    ROCM_HOME=/opt/rocm ROCM_TARGET=${ROCM_TARGET} make hip && \
    pip install .

# Install tokenizers
ENV PATH="$HOME/.cargo/bin:$PATH"
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y \
    && . "$HOME/.cargo/env" \
    && cd /opt && git clone https://github.com/huggingface/tokenizers \
    && cd tokenizers/bindings/python \
    && pip install . && rm -rf /root/.cache

# And finally all other relevant libraries
RUN pip install --no-cache-dir \
    git+https://github.com/huggingface/transformers \
    git+https://github.com/huggingface/peft \
    git+https://github.com/huggingface/accelerate.git \
    git+https://github.com/huggingface/datasets.git \
    git+https://github.com/huggingface/diffusers.git \
    git+https://github.com/Lightning-AI/lightning.git \
    scipy tensorboard pandas ipython \
    && rm -rf /root/.cache

WORKDIR /app
CMD [ "/bin/bash", "-l" ]
