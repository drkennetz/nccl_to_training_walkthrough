# compass_takehome benchmark image: a thin layer on NVIDIA's PyTorch container (arm64, Grace).
# The base carries torch + NCCL + CUDA; only the benchmark package and two diagnostic tools are
# added, so a rebuild pushes a few MB and the heavy layers stay shared with what the trays cache.
FROM nvcr.io/nvidia/pytorch@sha256:ace9a848c0ae543317e3c4763b6b4248961c47902625abfe3c77a0fb931c50fb
LABEL org.opencontainers.image.source="https://github.com/drkennetz/compass_takehome" \
      org.opencontainers.image.description="NCCL all-reduce sweep, DDP scaling workload, fabric counter watcher"
RUN apt-get update && apt-get install -y --no-install-recommends ethtool iproute2 rdma-core ibverbs-utils ndisc6 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/compass
COPY pyproject.toml README.md ./
COPY bench/ ./bench/
RUN pip install --no-cache-dir --no-deps . jsonschema
ENTRYPOINT ["python", "-m", "bench"]
CMD ["--help"]
