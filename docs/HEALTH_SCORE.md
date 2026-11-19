# Health score method

Each dimension starts at 100. Every deduction is recorded with its reason and shown in the app, CLI and reports.
The overall score is a weighted mean of the available dimensions. A dimension is excluded (not faked) when its data
is unavailable.

**Caps:** if any dimension is critical (<50), the overall score is capped at 49. If any is a warning (<80), it is
capped at 79. An average can therefore never hide an emergency. Status bands: ≥80 OK, 50–79 warning, <50 critical.

This score summarizes documented signals. It is **not** a hardware benchmark and does not predict performance gains.

| Dimension (weight) | Deduction | Points |
|---|---|---|
| Memory (3) | Kernel pressure WARNING / CRITICAL | 35 / 70 |
| | Swap growth ≥ threshold (default 2 GB/h, R² ≥ 0.5) | 15 |
| | Page-outs > 1000/min | 10 |
| | Compressed memory > 25% of RAM | 10 |
| CPU (2) | Sustained ≥85% for 10 min (≥80% of samples, ≥75% window coverage) | 35 |
| | Otherwise a single sample ≥90% | 10 |
| | 1-min load ≥4× / ≥2× logical CPUs | 20 / 10 |
| Thermal (2) | State fair / serious / critical | 15 / 50 / 80 |
| | ≥30 min at serious or worse in loaded history | 10 |
| Storage (2) | Free <5% / <10% / <20% | 70 / 40 / 15 |
| | Free < 15 GB (swap and OS updates need headroom) | 20 |
| GPU (1) | Sustained ≥85% for 10 min, or a single sample ≥95% | 25 / 5 |
| Battery (1) | Max capacity <80% (Apple's service guideline): 20 + 3 per point below 80, max 60 | 20–60 |
| | Max capacity 80–90%: 1.5 per point below 90 | 0–15 |

## Recommendation ranking

`priority = severity × benefit × (confidence ÷ 3) × safety × reversibility ÷ effort`, where:

- severity: critical 4, warning 3, info 1.5
- benefit and effort: low 1, medium 2, high 3
- safety: low risk 1, medium 0.6, high 0.3
- reversibility: 1 if reversible, 0.7 if not

Ranking is fully deterministic and covered by tests.
