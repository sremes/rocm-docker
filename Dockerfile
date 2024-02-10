FROM ubuntu:22.04

# Register the ROCM package repository, and install rocm-dev package
ARG ROCM_VERSION=6.0.2
ARG AMDGPU_VERSION=6.0.2

COPY 90-rocm-pin /etc/apt/preferences.d/rocm-pin-600
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -sL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/rocm.gpg \
    && echo "deb [arch=amd64] https://repo.radeon.com/rocm/apt/$ROCM_VERSION jammy main" | tee /etc/apt/sources.list.d/rocm.list \
    && echo "deb [arch=amd64] https://repo.radeon.com/amdgpu/$AMDGPU_VERSION/ubuntu jammy main" | tee /etc/apt/sources.list.d/amdgpu.list \
    && DEBIAN_FRONTEND=noninteractive apt-get --purge -y autoremove \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends  \
    build-essential rocm-dev rocm-libs rocm-utils rccl rocprofiler-dev roctracer-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install python and git + other tools
ARG PYTHON_VERSION=python3.12
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${PYTHON_VERSION} ${PYTHON_VERSION}-venv ${PYTHON_VERSION}-dev \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git less sudo vim unzip wget curl cmake autoconf automake libatlas-base-dev gfortran jq \
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
ENV HSA_OVERRIDE_GFX_VERSION=11.0.0
ARG ROCM_TARGET=gfx1100

# Install pytorch (nightly) - remove supplied rocm libraries and force torch and triton to use system versions
#RUN pip install --no-cache-dir --pre torch --index-url https://download.pytorch.org/whl/nightly/rocm6.0 \
#    && rm -rf /opt/venv/lib/${PYTHON_VERSION}/site-packages/torch/lib/{libMIOpen.so,libamd*,libdrm*,libhip*,libhsa-runtime64.so,libr*,rocblas,libelf.so,libgomp.so,libnuma.so} \
#    && rm -rf /opt/venv/lib/${PYTHON_VERSION}/site-packages/triton/third_party/hip/lib/{libamd*,libdrm*,libhsa-runtime64.so,libnuma.so,libelf.so} 
#RUN ln -sf /opt/rocm/lib/libamdhip64.so /opt/venv/lib/${PYTHON_VERSION}/site-packages/triton/third_party/hip/lib/ \
#RUN ln -sf /usr/lib/x86_64-linux-gnu/libgomp.so.1 /opt/venv/lib/${PYTHON_VERSION}/site-packages/torch/lib/libgomp.so

# Compile and install magma
RUN cd /opt && git clone https://bitbucket.org/icl/magma.git && cd magma && cp make.inc-examples/make.inc.hip-gcc-mkl make.inc \
    && echo 'LIBDIR += -L$(MKLROOT)/lib' | tee -a make.inc \
    && echo 'LIB += -Wl,--enable-new-dtags -Wl,--rpath,/opt/rocm/lib -Wl,--rpath,$(MKLROOT)/lib -Wl,--rpath,/opt/rocm/magma/lib' | tee -a make.inc \
    && echo 'DEVCCFLAGS += --gpu-max-threads-per-block=256' | tee -a make.inc \
    && echo 'DEVCCFLAGS += --offload-arch=$(ROCM_TARGET)' | tee -a make.inc \
    && sed -i 's/^FOPENMP/#FOPENMP/g' make.inc \
    && make -f make.gen.hipMAGMA -j $(nproc) \
    && LANG=C.UTF-8 make lib/libmagma.so -j $(nproc) MKLROOT=${MKLROOT} \
    && cd /opt && mv magma /opt/rocm

# Compile and install pytorch
ENV USE_LLVM=/opt/rocm/llvm
ENV LLVM_DIR=/opt/rocm/llvm/lib/cmake/llvm
ENV PYTORCH_ROCM_ARCH="gfx1100"
ENV ROCM_PATH /opt/rocm
ENV MAGMA_HOME /opt/rocm/magma
RUN pip install --no-cache-dir -U wheel setuptools
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ninja-build && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN cd /opt && git clone https://github.com/pytorch/pytorch.git && cd pytorch && pip install -r requirements.txt
RUN cd /opt/pytorch && python tools/amd_build/build_amd.py \
    && python setup.py bdist_wheel && pip install --no-index --no-deps "$(echo dist/*.whl)" && rm dist/*.whl

# Compile and install bitsandbytes for ROCm
RUN cd /opt && git clone https://github.com/sremes/bitsandbytes-rocm.git && \
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
