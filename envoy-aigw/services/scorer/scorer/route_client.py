"""AIGatewayRoute access: read the channel registry (rules -> backendRefs) and write back weights.

The route is the single source of truth for which channels exist; weights are patched in place with a JSON patch
so nothing else in the rule is touched. Envoy Gateway turns the new weights into locality weights via xDS within
seconds; no pod restarts.
"""

import logging

from kubernetes import client as k8s, config as k8s_config

log = logging.getLogger(__name__)

GROUP, VERSION, PLURAL = "aigateway.envoyproxy.io", "v1beta1", "aigatewayroutes"
MODEL_HEADER = "x-ai-eg-model"


class RouteClient:
    def __init__(self, namespace: str, name: str):
        try:
            k8s_config.load_incluster_config()
        except k8s_config.ConfigException:
            k8s_config.load_kube_config()
        self.api = k8s.CustomObjectsApi()
        self.namespace, self.name = namespace, name

    def _get(self) -> dict:
        return self.api.get_namespaced_custom_object(GROUP, VERSION, self.namespace, PLURAL, self.name)

    def load_channels(self) -> list[dict]:
        """[{model, channel_id, rule_index, ref_index, weight}] in route order."""
        out = []
        for ri, rule in enumerate(self._get()["spec"].get("rules", [])):
            model = next(
                (h.get("value") for m in rule.get("matches", []) for h in m.get("headers", []) if h.get("name") == MODEL_HEADER),
                None,
            )
            if not model:
                continue
            for bi, ref in enumerate(rule.get("backendRefs", [])):
                out.append({"model": model, "channel_id": ref["name"], "rule_index": ri, "ref_index": bi,
                            "weight": float(ref.get("weight", 1))})
        return out

    def current_weights(self, channels: list[dict]) -> dict[str, dict[str, float]]:
        """{model: {channel_id: normalized weight}} as currently configured."""
        live = {(c["model"], c["channel_id"]): c["weight"] for c in self.load_channels()}
        by_model: dict[str, dict[str, float]] = {}
        for c in channels:
            by_model.setdefault(c["model"], {})[c["channel_id"]] = live.get((c["model"], c["channel_id"]), c["weight"])
        for model, ws in by_model.items():
            total = sum(ws.values()) or 1.0
            by_model[model] = {cid: w / total for cid, w in ws.items()}
        return by_model

    def update_weights(self, channels: list[dict], model: str, weights: dict[str, int]) -> None:
        patch = [
            {"op": "replace", "path": f"/spec/rules/{c['rule_index']}/backendRefs/{c['ref_index']}/weight", "value": int(w)}
            for c in channels if c["model"] == model
            for w in [weights.get(c["channel_id"])] if w is not None
        ]
        if not patch:
            return
        # The client defaults to merge-patch for custom objects; a JSON patch array must say so explicitly
        self.api.patch_namespaced_custom_object(GROUP, VERSION, self.namespace, PLURAL, self.name, patch,
                                                _content_type="application/json-patch+json")
        log.info("model=%s weights patched: %s", model, weights)
