FROM ubuntu:24.04

# Register the ROCM package repository, and install rocm-dev package
ARG ROCM_VERSION=6.4
ARG AMDGPU_VERSION=6.4

COPY 90-rocm-pin /etc/apt/preferences.d/rocm-pin-600
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -sL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/rocm.gpg \
    && echo "deb [arch=amd64] https://repo.radeon.com/rocm/apt/$ROCM_VERSION noble main" | tee /etc/apt/sources.list.d/rocm.list \
    && echo "deb [arch=amd64] https://repo.radeon.com/amdgpu/$AMDGPU_VERSION/ubuntu noble main" | tee /etc/apt/sources.list.d/amdgpu.list \
    && DEBIAN_FRONTEND=noninteractive apt-get --purge -y autoremove \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends  \
    build-essential rocm-dev rocm-libs rocm-utils rocprofiler-dev roctracer-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install python and git + other tools
ARG PYTHON_VERSION=python3.12
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends software-properties-common \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${PYTHON_VERSION} ${PYTHON_VERSION}-venv ${PYTHON_VERSION}-dev \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ninja-build liblzma-dev pkg-config openssh-client git less sudo vim unzip wget curl cmake autoconf automake libatlas-base-dev gfortran jq libjpeg-dev libpng-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Intel MKL
ENV MKLROOT=/opt/intel/oneapi/mkl/latest
RUN wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
    | gpg --dearmor | tee /usr/share/keyrings/oneapi-archive-keyring.gpg > /dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" | tee /etc/apt/sources.list.d/oneAPI.list \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends intel-oneapi-mkl-devel \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Setup virtual environment
ENV LANG=C.UTF-8
SHELL ["/bin/bash", "-c"]
ENV VIRTUAL_ENV=/opt/venv
RUN ${PYTHON_VERSION} -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip install -U pip

# Select and enforce the ROCm gfx version
ENV HSA_OVERRIDE_GFX_VERSION=11.0.1
ARG ROCM_TARGET=gfx1101

# Install amd-smi tool, needed by pytorch/triton
RUN pip install /opt/rocm/share/amd_smi/ && rm -rf /root/.cache

# Compile and install magma
COPY magma_add_gfx1101.patch /opt
RUN cd /opt && git clone https://github.com/icl-utk-edu/magma.git \
    && cd magma \
    && git apply /opt/magma_add_gfx1101.patch \
    && cp make.inc-examples/make.inc.hip-gcc-mkl make.inc \
    && echo 'LIBDIR += -L$(MKLROOT)/lib' | tee -a make.inc \
    && echo 'LIB += -Wl,--enable-new-dtags -Wl,--rpath,/opt/rocm/lib -Wl,--rpath,$(MKLROOT)/lib -Wl,--rpath,/opt/rocm/magma/lib' | tee -a make.inc \
    && echo 'DEVCCFLAGS += --gpu-max-threads-per-block=256' | tee -a make.inc \
    && sed -i 's/^FOPENMP/#FOPENMP/g' make.inc \
    && make -f make.gen.hipMAGMA -j $(nproc) \
    && LANG=C.UTF-8 make lib/libmagma.so -j $(nproc) MKLROOT=${MKLROOT} \
    && cd /opt && mv magma /opt/rocm

# Compile and install pytorch
ENV USE_LLVM=/opt/rocm/llvm
ENV LLVM_DIR=/opt/rocm/llvm/lib/cmake/llvm
ENV PYTORCH_ROCM_ARCH="gfx1101"
ENV TARGET_GPUS="Navi32"
ENV ROCM_PATH=/opt/rocm
ENV MAGMA_HOME=/opt/rocm/magma
ENV BUILD_TEST=0
ENV USE_FLASH_ATTENTION=0
ENV USE_MEM_EFF_ATTENTION=0
ENV USE_DISTRIBUTED=0
RUN pip install --no-cache-dir -U wheel setuptools
RUN cd /opt && git clone https://github.com/pytorch/pytorch.git && cd pytorch && pip install -r requirements.txt
RUN cd /opt/pytorch && python tools/amd_build/build_amd.py \
    && python setup.py bdist_wheel && pip install --no-index --no-deps "$(echo dist/*.whl)" && rm dist/*.whl

# Install tokenizers
ENV PATH="$HOME/.cargo/bin:$PATH"
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y \
    && . "$HOME/.cargo/env" \
    && cd /opt && git clone https://github.com/huggingface/tokenizers \
    && cd tokenizers/bindings/python \
    && pip install . && rm -rf /root/.cache

# And finally all other relevant libraries
RUN pip install --no-cache-dir \
    git+https://github.com/Lightning-AI/lightning.git \
    transformers peft accelerate datasets diffusers \
    scipy tensorboard pandas matplotlib ipython pytest black \
    einops \
    && rm -rf /root/.cache

# Build Triton
RUN cd /opt && git clone https://github.com/triton-lang/triton.git \
    && cd triton && pip install -e python && rm -rf /root/.cache

# Build also torchvision
RUN cd /opt && git clone https://github.com/pytorch/vision.git \
    && cd vision && python setup.py install && rm -rf /root/.cache

# Flash-Attention with AMD Triton kernels
ENV GPU_ARCHS="gfx1101"
ENV FLASH_ATTENTION_TRITON_AMD_ENABLE="TRUE"
RUN cd /opt && git clone --recursive https://github.com/ROCm/flash-attention.git -b main_perf \
    && cd flash-attention \
    && pip install --no-build-isolation -e . && rm -rf /root/.cache

# Compile and install bitsandbytes for ROCm
RUN git clone -b multi-backend-refactor https://github.com/bitsandbytes-foundation/bitsandbytes.git \
    && cd bitsandbytes/  && cmake -DCOMPUTE_BACKEND=hip -DAMDGPU_TARGETS="gfx1101" -DBNB_ROCM_ARCH="gfx1101" -S . \
    && make -j $(nproc) && pip install -v -e .

# Add non-root user
ARG USERNAME=user
ARG USER_UID=1000
ARG USER_GID=100
RUN deluser --remove-home ubuntu && groupadd -f --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME -s /bin/bash \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME
USER $USERNAME

WORKDIR /app
CMD [ "/bin/bash", "-l" ]
