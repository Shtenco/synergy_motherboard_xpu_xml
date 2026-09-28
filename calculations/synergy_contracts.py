from __future__ import annotations
from hashlib import sha256
import json
from typing import Any

from xpu_v1_model import load_cfg, derive, energy_sweep

CONTRACT_ID = "synergy.runtime.hardware-model/v1"
AUTHORITY = "hardware_architecture_model"


def hardware_model_payload(*, model_id: str = "SHTENCO-XPU-V1") -> dict[str, Any]:
    cfg = load_cfg()
    if cfg.get("status") != "MODEL_NOT_SILICON":
        raise ValueError("unexpected XPU claim status")
    metrics = derive(cfg)
    sweep = energy_sweep(cfg, metrics)
    cfg_bytes = json.dumps(cfg, sort_keys=True, separators=(",", ":")).encode()
    return {
        "model_id": model_id,
        "model_status": "MODEL_NOT_SILICON",
        "config_sha256": sha256(cfg_bytes).hexdigest(),
        "eml_primitives_per_s": float(metrics["eml_primitives_per_s"]),
        "hbm_bytes_per_s": float(metrics["hbm_bytes_per_s"]),
        "active_silicon_mm2": float(metrics["active_silicon_mm2"]),
        "energy_sweep": [{"pj_per_primitive": pj, "modeled_watts": watts} for pj, watts in sweep],
        "measured_silicon": False,
        "deployment_authority": False,
    }
