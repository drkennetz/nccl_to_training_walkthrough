# compass_takehome — everything reproducible from one place.
PY      ?= .venv/bin/python
IMAGE   ?= ghcr.io/drkennetz/compass_takehome
TAG     ?= $(shell git rev-parse --short HEAD)
RESULTS ?= results/raw

.PHONY: venv test lint render render-check image image-push matrix analyze slides clean

venv:            ## local virtualenv with the dev extras (no torch)
	python3 -m venv .venv && .venv/bin/pip install -q -e '.[dev]'

test:            ## unit tests (no GPU, torch never imported)
	$(PY) -m pytest

lint:
	$(PY) -m ruff check . && $(PY) -m ruff format --check . && terraform fmt -check -recursive deploy/terraform

render:          ## matrix.yaml -> deploy/k8s/rendered/<run_id>/manifests.yaml
	$(PY) deploy/k8s/render.py

render-check:    ## fail if rendered/ is stale
	$(PY) deploy/k8s/render.py --check

image:           ## arm64 image, locally (the host is aarch64)
	docker build --platform linux/arm64 -t $(IMAGE):$(TAG) .

image-push: image
	docker push $(IMAGE):$(TAG)

matrix:          ## run every cell whose result is missing (needs KUBECONFIG)
	deploy/k8s/run_matrix.sh $(ARGS)

analyze:         ## results/raw -> tables, charts, SUMMARY.md, README block
	$(PY) -m analysis $(RESULTS)

slides:          ## results -> slides/compass.pptx
	$(PY) -m slides

clean:
	rm -rf .pytest_cache .ruff_cache results/tables/* results/charts/*
