# ATLAS on OpenShift + H200 benchmark runbook

This folder is the OpenShift/Hopper benchmark lane for ATLAS. It is intentionally
thin: keep the product runtime intact, build only the CUDA inference image for
Hopper (`CUDA_ARCH=90`), deploy the ATLAS services into one namespace, then run
baseline-vs-routed benchmark pairs against the cluster.

## Assumptions

- You are already logged in with `oc login`.
- You are working in a namespace where you can create `BuildConfig`,
  `ImageStream`, `Deployment`, `Service`, `Route`, `PVC`, and pods.
- NVIDIA GPU Operator/device-plugin support is already installed cluster-wide.
  The llama pod requests `nvidia.com/gpu: 1`.
- The selected GGUF model files live in a PVC mounted at `/models`.
- The model PVC must bind in a storage topology reachable from the H200 nodes.
  The included downloader pod uses the configured GPU node selector/toleration
  so a new `WaitForFirstConsumer` PVC binds on the right side of the cluster.

## 1. Configure

```bash
cp deploy/openshift/openshift.env.example deploy/openshift/openshift.env
$EDITOR deploy/openshift/openshift.env
```

Important fields:

- `ATLAS_NAMESPACE`: your OpenShift namespace.
- `ATLAS_MODEL_PVC`: PVC containing GGUF files.
- `ATLAS_MODEL_FILE`: the GGUF filename to load.
- `ATLAS_MAIN_MODEL`: display/model name; usually same as the filename.
- `ATLAS_CUDA_ARCH=90`: Hopper/H100/H200 build target.
- `ATLAS_GPU_NODE_SELECTOR_*` and `ATLAS_GPU_TOLERATION_*`: the H200 placement
  hints used by llama-server and the model downloader.

The default env creates a dedicated `atlas-models` PVC sized by
`ATLAS_MODELS_STORAGE`. If you want to reuse an existing PVC instead, set
`ATLAS_MODEL_PVC` to that claim name before deploying.

To create the configured PVC before downloading:

```bash
./scripts/openshift/apply-storage.sh deploy/openshift/openshift.env
```

Then download the configured model into the PVC:

```bash
./scripts/openshift/download-model-to-pvc.sh deploy/openshift/openshift.env
```

The example env defaults to the registry-pinned Qwen3.5-9B-Q6_K GGUF URL and
SHA-256. For Gemma, set `ATLAS_MODEL_URL`, `ATLAS_MODEL_FILE`, and
`ATLAS_MODEL_SHA256` once you have the GGUF source.

## 2. Build the Hopper llama-server image

```bash
./scripts/openshift/build-llama-hopper.sh deploy/openshift/openshift.env
```

This creates an OpenShift `BuildConfig` and builds `inference/Dockerfile.v31`
from the local `inference/` directory with `CUDA_ARCH=90` and
`GGML_NATIVE=OFF`. Disabling native CPU tuning keeps the image portable across
OpenShift build/runtime nodes while the CUDA kernels remain Hopper-targeted. The
resulting image is pushed to the namespace ImageStream configured by
`ATLAS_LLAMA_IMAGE`.

## 3. Deploy ATLAS services

```bash
./scripts/openshift/deploy.sh deploy/openshift/openshift.env
```

This creates:

- `atlas-llama-server` — GPU-bound llama.cpp server, one Hopper GPU.
- `atlas-geometric-lens` — C(x)/G(x) scoring service.
- `atlas-v3-service` — product V3 HTTP service.
- `atlas-sandbox` — code execution sandbox.
- `atlas-proxy` — agent/proxy entrypoint plus an OpenShift Route.

Only `atlas-llama-server` is Kueue/GPU-bound. The CPU services intentionally do
not carry the Kueue queue label, which avoids pinning PVC-backed CPU pods to the
H200 storage topology.

Wait until everything is ready:

```bash
oc get pods -l app.kubernetes.io/part-of=atlas-openshift
oc rollout status deploy/atlas-llama-server
oc rollout status deploy/atlas-geometric-lens
oc rollout status deploy/atlas-v3-service
oc rollout status deploy/atlas-sandbox
oc rollout status deploy/atlas-proxy
```

## 3b. Provide Lens artifacts for the deployed model

`atlas-geometric-lens` stays NotReady (`/ready` 503) until model-coupled
artifacts (`cost_field.pt`, G(x) bundle, `model_identity.json`) exist at
`/app/geometric_lens/models`. The published `atlas-lens` image ships no
artifacts; the runtime template mounts the `atlas-lens-state` PVC's
`lens-models/` subpath at that location, so artifacts survive image updates
and pod restarts.

To populate them, either copy an existing bundle for the deployed model:

```bash
oc rsync <local-artifact-dir>/ <lens-pod>:/data/state/lens-models/
oc rollout restart deploy/atlas-geometric-lens
```

or train fresh ones against the in-cluster llama-server (the lens image has
torch + xgboost; add scikit-learn with `pip install --user scikit-learn`).
The identity check is name- and dim-strict: `model_identity.json` must match
the served model (`/v1/models` id, e.g. `Qwen3.5-9B-Q6_K.gguf`) and the
embedding dim llama-server emits. The Qwen3.5-9B bundle here was trained on
the pre-computed 4096-dim labeled embeddings from
`huggingface.co/datasets/itigges22/ATLAS` (`embeddings/training_embeddings_4096d.json`).

## 4. Run a smoke benchmark pair

In one terminal:

```bash
./scripts/openshift/port-forward.sh deploy/openshift/openshift.env
```

In another terminal:

```bash
ATLAS_BENCH_MAX_TOKENS=256 ./scripts/openshift/run-benchmark-pair.sh qwen9b-smoke 10
```

That runs:

1. Baseline: `python -m benchmark.v3_runner --baseline`.
2. Routed: `python -m benchmark.v3_runner --selection-strategy lens`.

Both use the same cluster llama/lens endpoints via `LLAMA_URL` and
`RAG_API_URL`. Leave `ATLAS_BENCH_MAX_TOKENS` unset for full benchmark runs;
set it for smoke tests so a single task does not consume the full 8192-token
generation budget. When `ATLAS_BENCH_MAX_TOKENS` is set, the OpenShift helper
also allows an existing partial LiveCodeBench cache for smoke runs; unset
`ATLAS_LCB_ALLOW_PARTIAL_CACHE` or set it to `0` when you want a full dataset
refresh before a real run.

## 4b. Run the benchmark pair from inside the cluster

Long generation calls (e.g. the routed run's LLM self-test phase) are
unreliable through `oc port-forward`. `30-bench.yaml` deploys an idle
`atlas-bench` pod on the cluster network for exec-driven runs:

```bash
BENCH_POD=$(oc get pod -l app.kubernetes.io/name=atlas-bench -o name | head -1)
oc exec ${BENCH_POD#pod/} -- mkdir -p /bench/ATLAS
oc rsync --exclude=results --exclude=__pycache__ benchmark ${BENCH_POD#pod/}:/bench/ATLAS/
oc exec ${BENCH_POD#pod/} -- sh -c 'cd /bench/ATLAS && PYTHONPATH=/bench/ATLAS \
  ATLAS_BENCH_MAX_TOKENS=256 ATLAS_LCB_ALLOW_PARTIAL_CACHE=1 \
  python -m benchmark.v3_runner --run-id qwen9b-smoke_baseline_<stamp> --baseline --max-tasks 3 --max-tokens 256'
# then the routed run: --selection-strategy lens instead of --baseline
oc rsync ${BENCH_POD#pod/}:/bench/ATLAS/benchmark/results/ benchmark/results/
```

`LLAMA_URL` and `RAG_API_URL` are already set in the pod to the in-cluster
services. Results land on the `atlas-results` PVC (`/bench`), so they survive
pod restarts; rsync them back when the run finishes.

## 4c. Decontaminated eval: LCB release selection

The published lens training embeddings derive from LiveCodeBench v5
evaluations, so benchmarking on v5 tests partly-memorized problems.
`ATLAS_LCB_RELEASE` selects the LCB release (default `release_v5`); the
cache filename tracks the release.

LCB releases are cumulative — `release_v6` (1055 problems) contains nearly
all of v5 (880), so plain v6 is NOT decontaminated. Build a v6-minus-v5
cache instead: fetch both releases, keep v6 rows whose `question_id` is not
in v5 (175 problems), write them to
`benchmark/datasets/.cache/livecodebench_v6only.jsonl`, and run with
`ATLAS_LCB_RELEASE=release_v6only` — the loader uses any complete cache
matching the name without downloading. If the datasets-server rows API
502s (it does, persistently, on heavy v6 pages), fetch the parquet shards
from `huggingface.co/api/datasets/bzantium/livecodebench/parquet/<release>/test`
and apply the same row-slimming as the loader.

## 5. Run the Qwen/Gemma matrix

Edit `ATLAS_BENCH_MODELS` in `openshift.env`, then run:

```bash
./scripts/openshift/run-benchmark-matrix.sh deploy/openshift/openshift.env 10
```

The matrix script patches the deployed model filename/name, restarts the
model-dependent services, waits for rollout, and runs a baseline+routed pair
for each configured model. Increase the task count only after both models pass
smoke.

## Notes on interpretation

- `--baseline` disables V3 phases and measures the loaded model directly.
- The routed run enables the V3 pipeline with Lens selection. If a model has no
  compatible Lens artifacts, ATLAS will still run but the Lens path can degrade
  to default behavior; record that in the final report.
- Gemma-family GGUFs may require a newer pinned llama.cpp if the server reports
  `unknown model architecture 'gemma4'`.
- The benchmark runner executes candidate code locally in the process running
  the benchmark script, while model inference and Lens scoring happen in
  OpenShift through port-forwarded services.
