FROM ubuntu:24.04

# Register the ROCM package repository, and install rocm-dev package
ARG ROCM_VERSION=6.3.2
ARG AMDGPU_VERSION=6.3.2

COPY 90-rocm-pin /etc/apt/preferences.d/rocm-pin-600
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -sL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/rocm.gpg \
    && echo "deb [arch=amd64] https://repo.radeon.com/rocm/apt/$ROCM_VERSION noble main" | tee /etc/apt/sources.list.d/rocm.list \
    && echo "deb [arch=amd64] https://repo.radeon.com/amdgpu/$AMDGPU_VERSION/ubuntu noble main" | tee /etc/apt/sources.list.d/amdgpu.list \
    && DEBIAN_FRONTEND=noninteractive apt-get --purge -y autoremove \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends  \
    build-essential rocm-dev rocm-libs rocm-utils rccl rocprofiler-dev roctracer-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install python and git + other tools
ARG PYTHON_VERSION=python3.12
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends software-properties-common \
#    && add-apt-repository ppa:deadsnakes/ppa && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${PYTHON_VERSION} ${PYTHON_VERSION}-venv ${PYTHON_VERSION}-dev \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-client git less sudo vim unzip wget curl cmake autoconf automake libatlas-base-dev gfortran jq libjpeg-dev libpng-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Intel MKL
ENV MKLROOT=/opt/intel/oneapi/mkl/latest
RUN wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
    | gpg --dearmor | tee /usr/share/keyrings/oneapi-archive-keyring.gpg > /dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" | tee /etc/apt/sources.list.d/oneAPI.list \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends intel-oneapi-mkl-devel \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Setup virtual environment
SHELL ["/bin/bash", "-c"]
ENV VIRTUAL_ENV=/opt/venv
RUN ${PYTHON_VERSION} -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip install -U pip

# Select and enforce the ROCm gfx version
ENV HSA_OVERRIDE_GFX_VERSION=11.0.1
ARG ROCM_TARGET=gfx1101

# Install pytorch (nightly) - remove supplied rocm libraries and force torch and triton to use system versions
#RUN pip install --no-cache-dir --pre torch --index-url https://download.pytorch.org/whl/nightly/rocm6.0 \
#    && rm -rf /opt/venv/lib/${PYTHON_VERSION}/site-packages/torch/lib/{libMIOpen.so,libamd*,libdrm*,libhip*,libhsa-runtime64.so,libr*,rocblas,libelf.so,libgomp.so,libnuma.so} \
#    && rm -rf /opt/venv/lib/${PYTHON_VERSION}/site-packages/triton/third_party/hip/lib/{libamd*,libdrm*,libhsa-runtime64.so,libnuma.so,libelf.so} 
#RUN ln -sf /opt/rocm/lib/libamdhip64.so /opt/venv/lib/${PYTHON_VERSION}/site-packages/triton/third_party/hip/lib/ \
#RUN ln -sf /usr/lib/x86_64-linux-gnu/libgomp.so.1 /opt/venv/lib/${PYTHON_VERSION}/site-packages/torch/lib/libgomp.so

# Compile and install magma
COPY magma_add_gfx1101.patch /opt
RUN cd /opt && git clone https://github.com/icl-utk-edu/magma.git \
    && cd magma \
    && git apply /opt/magma_add_gfx1101.patch \
    && cp make.inc-examples/make.inc.hip-gcc-mkl make.inc \
    && echo 'LIBDIR += -L$(MKLROOT)/lib' | tee -a make.inc \
    && echo 'LIB += -Wl,--enable-new-dtags -Wl,--rpath,/opt/rocm/lib -Wl,--rpath,$(MKLROOT)/lib -Wl,--rpath,/opt/rocm/magma/lib' | tee -a make.inc \
    && echo 'DEVCCFLAGS += --gpu-max-threads-per-block=256' | tee -a make.inc \
#    && echo 'DEVCCFLAGS += --offload-arch=$(ROCM_TARGET)' | tee -a make.inc \
    && sed -i 's/^FOPENMP/#FOPENMP/g' make.inc \
    && make -f make.gen.hipMAGMA -j $(nproc) \
    && LANG=C.UTF-8 make lib/libmagma.so -j $(nproc) MKLROOT=${MKLROOT} \
    && cd /opt && mv magma /opt/rocm

# Compile and install pytorch
ENV USE_LLVM=/opt/rocm/llvm
ENV LLVM_DIR=/opt/rocm/llvm/lib/cmake/llvm
ENV PYTORCH_ROCM_ARCH="gfx1101"
ENV TARGET_GPUS="Navi32"
ENV ROCM_PATH /opt/rocm
ENV MAGMA_HOME /opt/rocm/magma
RUN pip install --no-cache-dir -U wheel setuptools
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ninja-build && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN cd /opt && git clone https://github.com/pytorch/pytorch.git && cd pytorch && pip install -r requirements.txt
RUN cd /opt/pytorch && python tools/amd_build/build_amd.py \
    && python setup.py bdist_wheel && pip install --no-index --no-deps "$(echo dist/*.whl)" && rm dist/*.whl

# Compile and install bitsandbytes for ROCm
RUN cd /opt && git clone https://github.com/ROCm/bitsandbytes.git \
    && cd bitsandbytes && git checkout rocm_enabled \
    && cmake -DCOMPUTE_BACKEND=hip -DBNB_ROCM_ARCH=${ROCM_TARGET} -S . \
    && make -j8 && pip install .

# Install tokenizers
ENV PATH="$HOME/.cargo/bin:$PATH"
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y \
    && . "$HOME/.cargo/env" \
    && cd /opt && git clone https://github.com/huggingface/tokenizers \
    && cd tokenizers/bindings/python \
    && pip install . && rm -rf /root/.cache

# And finally all other relevant libraries
RUN pip install --no-cache-dir \
    #git+https://github.com/huggingface/transformers \
    #git+https://github.com/huggingface/peft \
    #git+https://github.com/huggingface/accelerate.git \
    #git+https://github.com/huggingface/datasets.git \
    #git+https://github.com/huggingface/diffusers.git \
    git+https://github.com/Lightning-AI/lightning.git \
    transformers peft accelerate datasets diffusers \
    scipy tensorboard pandas matplotlib ipython pytest black \
    einops \
    && rm -rf /root/.cache

# Build Triton
#RUN cd /opt && git clone https://github.com/ROCm/triton.git \
#    && cd triton/python && pip install -e . && rm -rf /root/.cache
RUN cd /opt && git clone https://github.com/triton-lang/triton.git \
    && cd triton && pip install -e python && rm -rf /root/.cache

# Build Flash-Attention
#ENV GPU_ARCHS="gfx1101"
#COPY patch_flash_attn_arch.patch /opt
#RUN cd /opt && git clone --recursive https://github.com/ROCm/flash-attention.git \
#    && cd flash-attention && git checkout howiejay/navi_support \
#    && git apply /opt/patch_flash_attn_arch.patch \
#    && pip install -e . && rm -rf /root/.cache

# Build also torchvision
RUN cd /opt && git clone https://github.com/pytorch/vision.git \
    && cd vision && python setup.py install && rm -rf /root/.cache

# Install amd-smi tool, needed by pytorch/triton
RUN pip install /opt/rocm/share/amd_smi/ && rm -rf /root/.cache

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
