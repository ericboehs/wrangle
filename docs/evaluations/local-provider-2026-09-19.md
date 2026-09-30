# Local provider benchmark: Qwen3.5 9B OptiQ 4-bit

Date: 2026-09-19

## Setup

- Hardware: Apple M2 Max, 12 CPU cores, 64 GB unified memory.
- Runtime: oMLX 0.6.4, local OpenAI-compatible HTTP endpoint.
- Model: `Qwen3.5-9B-OptiQ-4bit`, mixed 4/8-bit MLX weights.
- On-disk size: 7,120,902,972 bytes (6.63 GiB).
- Benchmark client: Ruby standard library only; no new runtime dependency.
- Decoder: strict JSON schema containing an offered choice enum and a self-reported confidence.
- Suite: 20 deterministic desktop-decision cases in `script/benchmark_local_provider.rb`.

The model was already installed in the local oMLX model store, so this evaluation did not download another model or modify Wrangle's provider default. The endpoint stayed explicitly local. Screenshots, credentials, and live accessibility observations were not used.

## Results

| Measure | Result |
|---|---:|
| Correct | 17 / 20 |
| Accuracy | 85% |
| Warm median latency | 1,205 ms |
| Warm mean latency | 1,204 ms |
| Warm range | 1,067–1,393 ms |
| First request after a model switch | 9,246 ms |
| First uncached request observed separately | 62.0 s |
| Approximate loaded-memory increase | 7.46 GB |
| Mean self-reported confidence | 95% |
| Brier score | 0.1375 |
| Single-bin calibration error | 10 percentage points |

The separate uncached request reported 4.62 seconds of model loading and 56.94 seconds total server time. The memory figure is the oMLX engine-pool increase from 29.58 GB with one model loaded to 37.03 GB with two models loaded, not an isolated process peak.

Failures were safety-relevant:

1. It handed off rather than selecting an observed SSO control.
2. It toggled an already-checked setting instead of returning `DONE`.
3. It selected the first of two ambiguous duplicate controls instead of handing off.

Every case reported 0.95 confidence, including all failures. The model is therefore poorly calibrated for mutation gating and supplies no token-level probability distribution satisfying `wrangle.choice.v1`.

## Decision

**Assessment-only; not mutation-qualified and not a fallback.** The latency is usable for bounded local assessment, but 85% accuracy, an ambiguity failure, and non-discriminating confidence fail the alpha safety gate. Wrangle does not silently select this model or transition to it from a cloud provider. A future local adapter must expose a validated distribution over every offered choice and pass the canonical conformance suite before it can dispatch mutations.

Reproduce while the local oMLX endpoint is running:

```sh
script/benchmark_local_provider.rb > benchmark.json
```
