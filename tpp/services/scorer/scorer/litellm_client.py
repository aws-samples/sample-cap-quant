"""LiteLLM Management API 封装:渠道注册(/model/new)与权重更新(/model/{id}/update)。"""

import logging

import httpx
import yaml

log = logging.getLogger(__name__)


class LiteLLMClient:
    def __init__(self, base_url: str, master_key: str):
        self.http = httpx.Client(
            base_url=base_url,
            headers={"Authorization": f"Bearer {master_key}"},
            timeout=15.0,
        )

    def load_channels_spec(self, path: str) -> list[dict]:
        with open(path) as f:
            spec = yaml.safe_load(f)
        return spec["channels"]

    def list_models(self) -> dict[str, dict]:
        """{model_id: model_entry},来自 /model/info。"""
        r = self.http.get("/model/info")
        r.raise_for_status()
        return {
            m["model_info"]["id"]: m
            for m in r.json().get("data", [])
            if m.get("model_info", {}).get("id")
        }

    def ensure_channels(self, channels: list[dict]) -> None:
        """把渠道注册表同步进 LiteLLM DB(幂等:按稳定 model_info.id 判存在)。"""
        existing = self.list_models()
        for ch in channels:
            cid = ch["model_info"]["id"]
            if cid in existing:
                continue
            r = self.http.post("/model/new", json=ch)
            r.raise_for_status()
            log.info("registered channel %s (%s)", cid, ch["model_name"])

    def current_weights(self, channels: list[dict]) -> dict[str, float]:
        existing = self.list_models()
        out = {}
        for ch in channels:
            cid = ch["model_info"]["id"]
            if cid in existing:
                out[cid] = float(existing[cid].get("litellm_params", {}).get("weight", 50))
        total = sum(out.values()) or 1.0
        return {cid: w / total for cid, w in out.items()}

    def update_weight(self, model_id: str, weight: int) -> None:
        # PATCH = 部分更新,只改 weight,不动其余 litellm_params
        r = self.http.patch(
            f"/model/{model_id}/update",
            json={"litellm_params": {"weight": weight}},
        )
        r.raise_for_status()
