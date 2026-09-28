from synergy_contracts import CONTRACT_ID, hardware_model_payload

def test_xpu_model_stays_analytical():
    p=hardware_model_payload()
    assert CONTRACT_ID=="synergy.runtime.hardware-model/v1"
    assert p["model_status"]=="MODEL_NOT_SILICON"
    assert p["measured_silicon"] is False
    assert p["deployment_authority"] is False
    assert p["eml_primitives_per_s"]>0
