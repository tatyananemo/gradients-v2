> Исторический материал: относится к указанному ниже этапу/исходникам, а не к новой проверке `1b3c287`.
> Текущий статус V4-Optimized, границы точности масок/кадров, FPS и заполнение 9–10 с — в [RESULTS.md](../../../Documentation/RESULTS.md).
> Старые source guards могут намеренно отвергать поздние согласованные изменения; это не инструкция сборки optimized SDK.

# Optional V4 Simulator measurements

Build ordinary Release first. Set `GRADIENTS_PROFILE_APP` to its `.app` and optionally `GRADIENTS_SIMULATOR` to an already booted device UDID.

```sh
python3 -B Development/Validation/Performance/profile_simulator.py /tmp/v4-performance.json
python3 -B Development/Validation/Performance/validate_simulator_launches.py /tmp/v4-launches.json
```

The profiler uses the demo's opt-in deterministic idle/swipe/hold/release trace for Yellow Dark and Yellow Light. Duration is 20–90 seconds (`GRADIENTS_PROFILE_DURATION`). Results are GPU-completion cadence/CPU timings, not physical display FPS or touch-to-photon. The launch validator checks six V4 theme/progress combinations and observes render heartbeats/crash reports; it does not investigate cold-start performance. Neither tool records images or creates another app.

Mask pixel/reuse checks live in `Development/Validation/Masks`. Historical performance JSON was removed from the working tree because tests never consume it; original measurements remain in Git at `dc7b9da`. Never use another run's results as an unchanged GPU oracle.
