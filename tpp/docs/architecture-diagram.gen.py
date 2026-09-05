"""Generate docs/architecture-diagram.html (light theme) and docs/architecture-diagram.svg.

Usage: cd docs && python3 architecture-diagram.gen.py
PNG: Google Chrome --headless=new --force-device-scale-factor=2 --window-size=1200,830 \\
      --screenshot=architecture-diagram.png file://$PWD/architecture-diagram.svg
Icons (AWS Architecture Icons + OSS logos) are extracted from the existing HTML's <defs>, not duplicated here.
"""
import re
from pathlib import Path

HERE = Path(__file__).parent
# Icons are extracted from the previous HTML build (this script's own output, so regeneration stays reproducible)
OLD = (HERE / "architecture-diagram.html").read_text(encoding="utf-8")

defs = re.search(r"<defs>.*?</defs>", OLD, re.S).group(0)
defs = re.sub(r'\s*<pattern id="grid".*?</pattern>', "", defs, flags=re.S)
defs = defs.replace("<defs>", """<defs>
          <pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">
            <path d="M 40 0 L 0 0 0 40" fill="none" stroke="#e2e8f0" stroke-width="0.5"/>
          </pattern>""")
litellm_img = re.search(r'<image href="data:image/png;base64,[^"]+"', OLD).group(0)

# ---------- palette (light background) ----------
C = {
    "title": "#0f172a", "sub": "#475569", "muted": "#64748b",
    "cyan": "#0891b2", "cyan_f": "#ecfeff", "cyan_t": "#0e7490",
    "green": "#059669", "green_f": "#ecfdf5", "green_t": "#047857",
    "violet": "#7c3aed", "violet_f": "#f5f3ff", "violet_t": "#6d28d9",
    "amber": "#d97706", "amber_f": "#fffbeb", "amber_t": "#b45309",
    "rose": "#e11d48", "rose_f": "#fff1f2", "rose_t": "#be123c",
    "slate": "#64748b", "slate_f": "#f1f5f9", "slate_t": "#475569",
}


def box(x, y, w, h, color, dashed=False):
    dash = ' stroke-dasharray="4,4"' if dashed else ""
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="#ffffff"/>\n'
            f'        <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{C[color+"_f"]}" '
            f'stroke="{C[color]}" stroke-width="1.5"{dash}/>')


def t(x, y, s, size=9, fill="sub", weight=None, anchor="middle"):
    w = f' font-weight="{weight}"' if weight else ""
    a = f' text-anchor="{anchor}"' if anchor else ""
    return f'<text x="{x}" y="{y}" fill="{C.get(fill, fill)}" font-size="{size}"{w}{a}>{s}</text>'


SVG_BODY = f"""
        <!-- ============ Boundaries ============ -->
        <rect x="170" y="40" width="830" height="690" rx="12" fill="rgba(217,119,6,0.04)" stroke="{C['amber']}" stroke-width="1" stroke-dasharray="8,4"/>
        {t(182, 60, "AWS Account · us-west-2 (channels also span us-east-1)", 10, "amber_t", 600, "start")}
        <rect x="190" y="70" width="640" height="520" rx="12" fill="rgba(8,145,178,0.04)" stroke="{C['cyan']}" stroke-width="1" stroke-dasharray="8,4"/>
        <use href="#icon-eks" xlink:href="#icon-eks" x="200" y="78" width="20" height="20"/>
        {t(226, 92, "EKS Cluster: tpp-dev (3× m7i.large)", 10, "cyan_t", 600, "start")}

        <!-- ============ Connections (drawn first, layered beneath components) ============ -->
        <!-- Users → Bedrock direct (default) -->
        <path d="M 85 240 L 85 22 L 960 22 L 960 308" fill="none" stroke="{C['slate']}" stroke-width="1.2" stroke-dasharray="6,3" marker-end="url(#arrowhead)"/>
        {t(520, 16, "Direct to Bedrock (default for claude / codex, bypasses TPP; fallback path for troubleshooting)", 8, "muted")}
        <!-- Users → tunnel entry -->
        <line x1="160" y1="275" x2="208" y2="275" stroke="{C['cyan']}" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        {t(184, 267, "TPP key", 7.5, "muted")}
        <!-- Entry → LiteLLM -->
        <line x1="335" y1="275" x2="378" y2="275" stroke="{C['cyan']}" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        {t(357, 267, ":14000", 7, "cyan_t")}
        <!-- Entry → Dashboard (:3020) -->
        <line x1="250" y1="243" x2="250" y2="172" stroke="{C['cyan']}" stroke-width="1.2" marker-end="url(#arrowhead)"/>
        {t(254, 212, ":3020", 7, "cyan_t", None, "start")}
        <!-- Dashboard → Prometheus (query) -->
        <line x1="362" y1="118" x2="618" y2="118" stroke="{C['slate']}" stroke-width="1.2" stroke-dasharray="4,4" marker-end="url(#arrowhead)"/>
        {t(490, 111, "PromQL: litellm_* / scorer_*", 7.5, "muted")}
        <!-- Dashboard → LiteLLM Management API -->
        <path d="M 330 172 L 330 205 L 440 205 L 440 238" fill="none" stroke="{C['slate']}" stroke-width="1.2" stroke-dasharray="4,4" marker-end="url(#arrowhead)"/>
        {t(380, 199, "/user/* quota read/write", 7.5, "muted")}
        <!-- Prometheus → LiteLLM (scrape) -->
        <path d="M 618 148 L 500 148 L 500 238" fill="none" stroke="{C['slate']}" stroke-width="1.2" stroke-dasharray="4,4" marker-end="url(#arrowhead)"/>
        {t(559, 141, "scrape /metrics", 7.5, "muted")}
        <!-- Prometheus → Grafana -->
        <line x1="695" y1="160" x2="695" y2="198" stroke="{C['slate']}" stroke-width="1.2" marker-end="url(#arrowhead)"/>
        <!-- LiteLLM → Langfuse (callback) -->
        <path d="M 530 305 L 575 305 L 575 370 L 618 370" fill="none" stroke="{C['green']}" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        {t(583, 336, "langfuse_otel", 7, "green_t", None, "start")}
        <!-- Langfuse → ClickHouse -->
        <line x1="695" y1="400" x2="695" y2="438" stroke="{C['violet']}" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        <!-- Scorer → Prometheus ① -->
        <path d="M 530 435 L 800 435 L 800 130 L 772 130" fill="none" stroke="{C['amber']}" stroke-width="1.2" stroke-dasharray="5,3" marker-end="url(#arrowhead)"/>
        {t(806, 290, "① query metrics", 8, "amber_t", None, "start")}
        <!-- Scorer → LiteLLM ③ -->
        <line x1="455" y1="420" x2="455" y2="332" stroke="{C['amber']}" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        {t(462, 380, "③ PATCH weight", 8, "amber_t", None, "start")}
        <!-- LiteLLM → Bedrock -->
        <path d="M 530 300 L 815 300 L 815 360 L 853 360" fill="none" stroke="{C['amber']}" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        {t(672, 292, "AWS SDK · SigV4 (IRSA, zero static keys)", 8, "amber_t")}
        <!-- LiteLLM → external channels (reserved) -->
        <path d="M 530 262 L 570 262 L 570 52 L 1105 52 L 1105 88" fill="none" stroke="{C['slate']}" stroke-width="1" stroke-dasharray="4,4" marker-end="url(#arrowhead)"/>
        {t(840, 46, "HTTPS + API Key (reserved, not enabled)", 8, "muted")}
        <!-- LiteLLM → RDS -->
        <path d="M 380 318 L 250 318 L 250 638" fill="none" stroke="{C['violet']}" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        {t(256, 470, "keys · budget · spend", 8, "violet_t", None, "start")}
        <!-- Scorer → Redis -->
        <line x1="455" y1="490" x2="455" y2="638" stroke="{C['violet']}" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        {t(462, 575, "EWMA · breaker state", 8, "violet_t", None, "start")}
        <!-- Langfuse → S3 -->
        <path d="M 618 385 L 600 385 L 600 638" fill="none" stroke="{C['amber']}" stroke-width="1" marker-end="url(#arrowhead)"/>
        {t(596, 560, "events", 8, "muted", None, "end")}
        <!-- Secrets Manager → ESO -->
        <line x1="760" y1="638" x2="760" y2="580" stroke="{C['rose']}" stroke-width="1.2" stroke-dasharray="4,4" marker-end="url(#arrowhead)"/>
        {t(766, 612, "5m poll", 8, "rose_t", None, "start")}
        <!-- Bedrock → CloudWatch -->
        <line x1="920" y1="440" x2="920" y2="478" stroke="{C['amber']}" stroke-width="1" stroke-dasharray="4,4" marker-end="url(#arrowhead)"/>

        <!-- ============ Components ============ -->
        <!-- Users -->
        {box(10, 240, 150, 80, "slate")}
        {t(85, 261, "Users · Claude Code · Codex", 8.5, "title", 600)}
        {t(85, 278, "laptop · per-user key", 8.5)}
        {t(85, 293, "claude-tpp · codex --profile tpp", 7, "muted")}
        {t(85, 308, "Dual mode: direct ⇄ via TPP", 7.5, "muted")}

        <!-- Tunnel entry -->
        {box(210, 245, 125, 60, "cyan")}
        <use href="#icon-elb" xlink:href="#icon-elb" x="215" y="263" width="22" height="22"/>
        {t(286, 265, "Tunnel Entry", 11, "title", 600)}
        {t(286, 281, "launchd daemons · 5 tunnels", 8)}
        {t(286, 295, "watchdog 15s×3 · ALB reserved", 7, "cyan_t")}

        <!-- TPP Dashboard -->
        {box(210, 100, 150, 70, "green")}
        {t(285, 121, "TPP Dashboard", 12, "title", 600)}
        {t(285, 138, "Unified portal · editable quotas", 9)}
        {t(285, 151, "Channel spend · health · weights", 8)}
        {t(285, 163, "TTFT / TPOT / E2E / TPS pctl", 7.5, "green_t")}

        <!-- LiteLLM -->
        {box(380, 240, 150, 90, "green")}
        {litellm_img} x="385" y="245" width="20" height="20"/>
        {t(470, 262, "LiteLLM Proxy", 12, "title", 600)}
        {t(470, 280, "Deployment ×2", 9)}
        {t(470, 295, "USD quota · weight routing", 9)}
        {t(470, 313, ":4000 · /v1 · /ui", 8, "green_t")}

        <!-- Prometheus -->
        {box(620, 100, 150, 60, "slate")}
        <use href="#icon-prometheus" xlink:href="#icon-prometheus" x="628" y="117" width="26" height="26"/>
        {t(712, 122, "Prometheus", 11, "title", 600)}
        {t(712, 138, "kube-prometheus-stack", 8)}
        {t(712, 151, "15d PVC · Alertmanager", 8)}

        <!-- Grafana -->
        {box(620, 200, 150, 50, "slate")}
        <use href="#icon-grafana" xlink:href="#icon-grafana" x="628" y="212" width="26" height="26"/>
        {t(712, 220, "Grafana", 11, "title", 600)}
        {t(712, 237, "TPP Overview + 4 alerts", 8)}

        <!-- Langfuse -->
        {box(620, 340, 150, 60, "green")}
        <use href="#icon-langfuse" xlink:href="#icon-langfuse" x="628" y="357" width="26" height="26"/>
        {t(712, 362, "Langfuse v4", 11, "title", 600)}
        {t(712, 379, "Web + Worker", 9)}
        {t(712, 392, "LLM call traces", 8)}

        <!-- ClickHouse -->
        {box(620, 440, 150, 50, "violet")}
        {t(695, 460, "ClickHouse", 11, "title", 600)}
        {t(695, 477, "Single-node STS · gp3 PVC", 8)}

        <!-- ESO + Reloader -->
        {box(620, 532, 150, 45, "rose")}
        {t(695, 548, "ESO + Reloader", 10.5, "title", 600)}
        {t(695, 561, "Secret change → rolling restart", 8)}
        {t(695, 572, "Auto-recovery from RDS 7d rotation", 7, "rose_t")}

        <!-- Scorer -->
        {box(380, 420, 150, 70, "green")}
        {t(455, 442, "Scorer", 12, "title", 600)}
        {t(455, 460, "② scoring · EWMA · breaker", 9)}
        {t(455, 478, "60s cycle · single replica", 8, "green_t")}

        <!-- Bedrock -->
        {box(855, 310, 130, 130, "amber")}
        <use href="#icon-bedrock" xlink:href="#icon-bedrock" x="905" y="320" width="30" height="30"/>
        {t(920, 368, "Amazon Bedrock", 11, "title", 600)}
        {t(920, 385, "us-west-2 / us-east-1", 9)}
        {t(920, 400, "4 Claude groups × 2 regions", 8)}
        {t(920, 414, "+ Mantle gpt-5.6-terra", 8)}
        {t(920, 429, "= 9 channels · IRSA", 8, "amber_t")}

        <!-- CloudWatch -->
        {box(855, 480, 130, 50, "amber")}
        <use href="#icon-cloudwatch" xlink:href="#icon-cloudwatch" x="862" y="493" width="24" height="24"/>
        {t(936, 500, "CloudWatch", 10, "title", 600)}
        {t(936, 517, "Server-side metrics · debug", 7)}

        <!-- External channels (reserved) -->
        {box(1030, 90, 150, 120, "slate", dashed=True)}
        {t(1105, 112, "External channels (reserved)", 11, "title", 600)}
        {t(1105, 134, "Anthropic API", 9)}
        {t(1105, 150, "OpenAI API", 9)}
        {t(1105, 166, "OpenRouter (aggregator)", 9)}
        {t(1105, 188, "Add to registry to onboard", 8)}

        <!-- RDS -->
        {box(210, 640, 150, 60, "violet")}
        <use href="#icon-rds" xlink:href="#icon-rds" x="218" y="657" width="26" height="26"/>
        {t(301, 662, "RDS PostgreSQL", 10.5, "title", 600)}
        {t(301, 680, "litellm accounting + langfuse", 8)}
        {t(301, 693, "Managed master pwd · 7d rotation", 7, "violet_t")}

        <!-- ElastiCache -->
        {box(390, 640, 130, 60, "violet")}
        <use href="#icon-elasticache" xlink:href="#icon-elasticache" x="396" y="657" width="26" height="26"/>
        {t(473, 662, "ElastiCache", 10.5, "title", 600)}
        {t(473, 680, "Redis · budget sync", 8)}
        {t(473, 693, "Routing · Scorer state", 8)}

        <!-- S3 -->
        {box(550, 640, 110, 60, "amber")}
        <use href="#icon-s3" xlink:href="#icon-s3" x="556" y="657" width="26" height="26"/>
        {t(621, 662, "S3", 10.5, "title", 600)}
        {t(621, 680, "Langfuse events", 8)}
        {t(621, 693, "90d lifecycle", 8)}

        <!-- Secrets Manager -->
        {box(690, 640, 140, 60, "rose")}
        <use href="#icon-secrets" xlink:href="#icon-secrets" x="696" y="657" width="26" height="26"/>
        {t(778, 662, "Secrets Manager", 10, "title", 600)}
        {t(778, 680, "tpp/* · RDS master password", 8)}
        {t(778, 693, "Kept out of tfstate", 8)}

        <!-- ============ Legend ============ -->
        {t(190, 766, "Legend", 10, "title", 600, "start")}
        <rect x="190" y="776" width="16" height="10" rx="2" fill="{C['cyan_f']}" stroke="{C['cyan']}" stroke-width="1"/>
        {t(212, 785, "Entry / K8s boundary", 8, "sub", None, "start")}
        <rect x="330" y="776" width="16" height="10" rx="2" fill="{C['green_f']}" stroke="{C['green']}" stroke-width="1"/>
        {t(352, 785, "App services", 8, "sub", None, "start")}
        <rect x="430" y="776" width="16" height="10" rx="2" fill="{C['violet_f']}" stroke="{C['violet']}" stroke-width="1"/>
        {t(452, 785, "Data stores", 8, "sub", None, "start")}
        <rect x="525" y="776" width="16" height="10" rx="2" fill="{C['amber_f']}" stroke="{C['amber']}" stroke-width="1"/>
        {t(547, 785, "AWS managed / channels", 8, "sub", None, "start")}
        <rect x="675" y="776" width="16" height="10" rx="2" fill="{C['rose_f']}" stroke="{C['rose']}" stroke-width="1"/>
        {t(697, 785, "Security / secrets", 8, "sub", None, "start")}
        <rect x="805" y="776" width="16" height="10" rx="2" fill="{C['slate_f']}" stroke="{C['slate']}" stroke-width="1"/>
        {t(827, 785, "External / observability", 8, "sub", None, "start")}
        <line x1="190" y1="801" x2="212" y2="801" stroke="{C['amber']}" stroke-width="1.2" stroke-dasharray="5,3"/>
        {t(218, 805, "①②③ Scorer control loop", 8, "sub", None, "start")}
        <line x1="430" y1="801" x2="452" y2="801" stroke="{C['slate']}" stroke-width="1.2" stroke-dasharray="6,3"/>
        {t(458, 805, "Direct / reserved / read-only query", 8, "sub", None, "start")}
"""

FONT = "'JetBrains Mono','SF Mono',Menlo,Consolas,monospace"

# ---------- standalone SVG ----------
svg = f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1200 830" width="1200" height="830" font-family="{FONT}">
        {defs}
        <rect x="0" y="0" width="1200" height="830" fill="#f8fafc"/>
        <rect x="0" y="0" width="1200" height="830" fill="url(#grid)"/>
{SVG_BODY}
</svg>
"""
(HERE / "architecture-diagram.svg").write_text(svg, encoding="utf-8")

# ---------- HTML ----------
html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>TPP — Token Proxy Platform Architecture</title>
  <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
  <script src="https://cdn.jsdelivr.net/npm/html2canvas@1.4.1/dist/html2canvas.min.js" integrity="sha384-ZZ1pncU3bQe8y31yfZdMFdSpttDoPmOZg2wguVK9almUodir1PghgT0eY7Mrty8H" crossorigin="anonymous"></script>
  <script src="https://cdn.jsdelivr.net/npm/jspdf@2.5.2/dist/jspdf.umd.min.js" integrity="sha384-en/ztfPSRkGfME4KIm05joYXynqzUgbsG5nMrj/xEFAHXkeZfO3yMK8QQ+mP7p1/" crossorigin="anonymous"></script>
  <style>
    * {{ margin: 0; padding: 0; box-sizing: border-box; }}
    html {{ background: #f8fafc; }}
    body {{ font-family: {FONT}; background: #f8fafc; min-height: 100vh; padding: 2rem; color: #0f172a; }}
    .container {{ max-width: 1300px; margin: 0 auto; }}
    .header {{ margin-bottom: 1.5rem; }}
    .header-row {{ display: flex; align-items: center; gap: 1rem; margin-bottom: 0.5rem; }}
    .pulse-dot {{ width: 12px; height: 12px; background: #0891b2; border-radius: 50%; animation: pulse 2s infinite; }}
    @keyframes pulse {{ 0%, 100% {{ opacity: 1; }} 50% {{ opacity: 0.5; }} }}
    h1 {{ font-size: 1.5rem; font-weight: 700; letter-spacing: -0.025em; color: #0f172a; }}
    .subtitle {{ color: #475569; font-size: 0.875rem; margin-left: 1.75rem; }}
    .diagram-container {{ background: #ffffff; border: 1px solid #e2e8f0; border-radius: 1rem; padding: 1.5rem; overflow-x: auto; }}
    svg {{ width: 100%; min-width: 1000px; display: block; }}
    .cards {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 1rem; margin-top: 1.5rem; }}
    .card {{ background: #ffffff; border-radius: 0.75rem; border: 1px solid #e2e8f0; padding: 1.25rem; }}
    .card-header {{ display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.75rem; }}
    .card-dot {{ width: 8px; height: 8px; border-radius: 50%; }}
    .card-dot.cyan {{ background: #0891b2; }}
    .card-dot.emerald {{ background: #059669; }}
    .card-dot.violet {{ background: #7c3aed; }}
    .card-dot.amber {{ background: #d97706; }}
    .card-dot.rose {{ background: #e11d48; }}
    .card h3 {{ font-size: 0.875rem; font-weight: 600; color: #0f172a; }}
    .card ul {{ list-style: none; color: #475569; font-size: 0.75rem; }}
    .card li {{ margin-bottom: 0.375rem; }}
    .footer {{ text-align: center; margin-top: 1.5rem; color: #64748b; font-size: 0.75rem; }}
    .toolbar {{ display: flex; gap: 0.5rem; margin-left: auto; flex-shrink: 0; align-items: center; }}
    .toolbar-toggle {{ background: transparent; border: none; color: #64748b; cursor: pointer; font-size: 1.25rem; line-height: 1; padding: 0.25rem 0.5rem; border-radius: 0.375rem; transition: color 0.2s, background 0.2s; }}
    .toolbar-toggle:hover {{ color: #0f172a; background: #e2e8f0; }}
    .toolbar-actions {{ display: none; gap: 0.5rem; }}
    .toolbar.expanded .toolbar-actions {{ display: flex; }}
    .toolbar-actions button {{ background: #ffffff; border: 1px solid #cbd5e1; color: #475569; padding: 0.375rem 0.75rem; border-radius: 0.375rem; font-family: inherit; font-size: 0.75rem; cursor: pointer; transition: all 0.2s; white-space: nowrap; }}
    .toolbar-actions button:hover {{ background: #f1f5f9; color: #0f172a; border-color: #94a3b8; }}
    @media print {{ body {{ background: #ffffff; padding: 1rem; }} .toolbar {{ display: none !important; }} }}
  </style>
</head>
<body>
  <div class="container" id="report-container">
    <div class="header">
      <div class="header-row">
        <div class="pulse-dot"></div>
        <h1>TPP — Token Proxy Platform</h1>
        <div class="toolbar">
          <div class="toolbar-actions">
            <button onclick="copyAsImage(this)">📋 Copy</button>
            <button onclick="downloadPNG(this)">🖼️ PNG</button>
            <button onclick="downloadPDF(this)">📄 PDF</button>
          </div>
          <button class="toolbar-toggle" onclick="this.parentElement.classList.toggle('expanded')" title="Export options" aria-label="Export options">⋯</button>
        </div>
      </div>
      <p class="subtitle">Unified LLM channel proxy: USD quota · Metrics · Trace · Intelligent weight scheduling · Unified portal Dashboard — EKS tpp-dev · us-west-2</p>
    </div>

    <div class="diagram-container">
      <svg viewBox="0 0 1200 830" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
        {defs}
        <rect x="0" y="0" width="1200" height="830" fill="#ffffff"/>
        <rect x="0" y="0" width="1200" height="830" fill="url(#grid)"/>
{SVG_BODY}
      </svg>
    </div>

    <div class="cards">
      <div class="card">
        <div class="card-header">
          <div class="card-dot emerald"></div>
          <h3>Core Path · Dual-Mode Access</h3>
        </div>
        <ul>
          <li>• LiteLLM Proxy ×2, OpenAI-compatible + Anthropic-native dual protocol (:4000, local tunnel :14000)</li>
          <li>• Per-user USD quota, deducted in real time from actual spend, auto-resets every 1d</li>
          <li>• 9 channels = 4 Claude model groups × 2 Bedrock regions + gpt-5.6-terra (Bedrock Mantle, for Codex); IRSA, zero static keys</li>
          <li>• Clients hit Bedrock directly by default; switch to TPP on demand via claude-tpp / codex --profile tpp. A TPP outage never affects the troubleshooting assistant</li>
        </ul>
      </div>
      <div class="card">
        <div class="card-header">
          <div class="card-dot cyan"></div>
          <h3>Observability · Unified Portal</h3>
        </div>
        <ul>
          <li>• TPP Dashboard (:3020): user quotas editable with write-back, channel spend / health / weights, TTFT / TPOT / E2E / TPS percentiles, links to the other four UIs</li>
          <li>• Prometheus 15d: TTFT / TPOT / E2E / Error (channel × model); Grafana TPP Overview + 4 alerts</li>
          <li>• Langfuse v4 traces (langfuse_otel, OTLP) → ClickHouse + S3; accounting data lives in RDS</li>
          <li>• Dashboard / Prometheus have no auth of their own; security relies on no exposed Ingress and tunnel-only access</li>
        </ul>
      </div>
      <div class="card">
        <div class="card-header">
          <div class="card-dot amber"></div>
          <h3>Scorer Scheduling · Security &amp; Resilience</h3>
        </div>
        <ul>
          <li>• Every 60s: quality_score = 0.35 × latency_score + 0.65 × error_score; EWMA α=0.3, γ=2 amplifies score gaps → weight, state kept in Redis</li>
          <li>• 5% exploration floor prevents lockout; breaker zeroes a channel when severe errors dominate; 2pp hysteresis on write-back; weights freeze when dependencies are unavailable</li>
          <li>• RDS managed master password, 7d rotation: ESO polls every 5m → Reloader rolling-restarts LiteLLM / Langfuse, no manual intervention</li>
          <li>• Local tunnels run as launchd daemons, each with a health-probe watchdog (rebuilt after 3 failed 15s probes)</li>
        </ul>
      </div>
    </div>

    <p class="footer">
      TPP · Deployed with Terraform (separate infra + apps states) + Helm · Source: docs/architecture.md · Decision records: docs/ADR.md · Icons: AWS Architecture Icons · OSS logos © the Prometheus / Grafana / Langfuse / LiteLLM projects
    </p>
  </div>

  <script>
    async function capture() {{
      const el = document.getElementById('report-container');
      const r = el.getBoundingClientRect();
      const pad = 32;
      return html2canvas(document.body, {{ backgroundColor: '#f8fafc', scale: 2, useCORS: true, ignoreElements: (e) => e.classList && e.classList.contains('toolbar'), x: r.left + window.scrollX - pad, y: r.top + window.scrollY - pad, width: r.width + pad * 2, height: r.height + pad * 2 }});
    }}
    async function copyAsImage(btn) {{
      const orig = btn.textContent;
      try {{
        const canvas = await capture();
        const blob = await new Promise(r => canvas.toBlob(r, 'image/png'));
        await navigator.clipboard.write([new ClipboardItem({{ 'image/png': blob }})]);
        btn.textContent = '✓ Copied!';
      }} catch (e) {{ btn.textContent = '✗ Failed'; }}
      setTimeout(() => btn.textContent = orig, 2000);
    }}
    async function downloadPNG(btn) {{
      const orig = btn.textContent; btn.textContent = '⏳ ...';
      try {{
        const canvas = await capture();
        const link = document.createElement('a');
        link.download = 'tpp-architecture.png'; link.href = canvas.toDataURL('image/png'); link.click();
        btn.textContent = '✓ Done!';
      }} catch (e) {{ btn.textContent = '✗ Failed'; }}
      setTimeout(() => btn.textContent = orig, 2000);
    }}
    async function downloadPDF(btn) {{
      const orig = btn.textContent; btn.textContent = '⏳ ...';
      try {{
        const canvas = await capture();
        const {{ jsPDF }} = window.jspdf;
        const orientation = canvas.width > canvas.height ? 'landscape' : 'portrait';
        const pdf = new jsPDF({{ orientation, unit: 'px', format: [canvas.width, canvas.height], hotfixes: ['px_scaling'] }});
        pdf.addImage(canvas.toDataURL('image/png'), 'PNG', 0, 0, canvas.width, canvas.height);
        pdf.save('tpp-architecture.pdf');
        btn.textContent = '✓ Done!';
      }} catch (e) {{ btn.textContent = '✗ Failed'; }}
      setTimeout(() => btn.textContent = orig, 2000);
    }}
  </script>
</body>
</html>
"""
(HERE / "architecture-diagram.html").write_text(html, encoding="utf-8")
print("ok")
