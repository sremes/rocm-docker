# rocm-docker

Build a Docker image based on Ubuntu 24.04 that contains
- ROCm from official AMD repos
- Python 3.12 (from deadsnakes/ppa)
- PyTorch compiled from source (from git master branch)
- Transformers, PEFT, bitsandbytes etc.

By default, sets the device to gfx1101 (i.e. compatible with 7800XT).
