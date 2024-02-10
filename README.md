# rocm-docker

Docker image based on Ubuntu 22.04 that contains
- ROCm from AMD repos
- Python 3.12 (from deadsnakes/ppa)
- PyTorch compiled from source (from gitmaster branch)
- Transformers, PEFT, etc. (from git)
- Modified fork of bitsandbytes for ROCm

By default, sets the device to gfx1100 (i.e. compatible with 7800XT/7900XTX).
