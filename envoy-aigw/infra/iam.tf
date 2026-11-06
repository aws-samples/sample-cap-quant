# All in-cluster AWS access uses EKS Pod Identity (no static keys, no OIDC provider per role).
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# ---- EBS CSI (Prometheus / Redis volumes) ----
resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---- Envoy AI Gateway -> Bedrock (runtime + mantle) ----
data "aws_iam_policy_document" "bedrock_invoke" {
  statement {
    sid    = "InvokeModels"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream",
    ]
    # Cross-region inference profiles fan out to other US regions, so foundation-model ARNs must be allowed
    # in every region. Inference-profile ARNs are allowed in every region too: the gateway calls a second
    # Bedrock endpoint (us-east-1) as the failover channel for each model.
    resources = [
      "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/*",
      "arn:${data.aws_partition.current.partition}:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*",
    ]
  }

  statement {
    sid       = "MantleOpenAICompatible"
    effect    = "Allow"
    actions   = ["bedrock-mantle:CreateInference"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "bedrock_invoke" {
  name   = "${local.name}-bedrock-invoke"
  policy = data.aws_iam_policy_document.bedrock_invoke.json
}

resource "aws_iam_role" "aigw_bedrock" {
  name               = "${local.name}-aigw-bedrock"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "aigw_bedrock" {
  role       = aws_iam_role.aigw_bedrock.name
  policy_arn = aws_iam_policy.bedrock_invoke.arn
}

# ---- AWS Load Balancer Controller ----
# Policy document is vendored from the upstream release (apps layer pins the chart version to match).
resource "aws_iam_policy" "alb_controller" {
  name   = "${local.name}-alb-controller"
  policy = file("${path.module}/policies/alb-controller-iam-policy.json")
}

resource "aws_iam_role" "alb_controller" {
  name               = "${local.name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}
