# rocm-docker
Docker image based on Ubuntu 22.04 that contains
- ROCm from AMD repos
- Python 3.11 (from deadsnakes/ppa)
- PyTorch (*nightly* from pytorch.org) compiled for ROCm
- Transformers, PEFT, etc. (from *git*)
- Modified fork of bitsandbytes for ROCm

By default, sets the device to gfx1100 (i.e. compatible with 7800XT/7900XTX).
