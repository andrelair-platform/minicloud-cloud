# Scoped RUNTIME identity for LiteLLM to invoke AWS Bedrock (story #299).
# Least-privilege: InvokeModel only. This is NOT the provisioning identity —
# that's the separate `minicloud-tofu` IAM user (admin, replaced the root key).
# Its access key is consumed by LiteLLM via Vault→ESO→env (wired in #303/E1).

resource "aws_iam_user" "litellm_bedrock" {
  name = "litellm-bedrock"
  tags = { project = "minicloud", purpose = "bedrock-runtime" }
}

data "aws_iam_policy_document" "bedrock_invoke" {
  statement {
    sid    = "BedrockInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    # Any foundation model — actual access is still gated per-model/region by
    # Bedrock model-access enablement (#303). Least-privilege on the ACTION.
    resources = ["arn:aws:bedrock:*::foundation-model/*"]
  }
}

resource "aws_iam_user_policy" "litellm_bedrock" {
  name   = "bedrock-invoke"
  user   = aws_iam_user.litellm_bedrock.name
  policy = data.aws_iam_policy_document.bedrock_invoke.json
}

resource "aws_iam_access_key" "litellm_bedrock" {
  user = aws_iam_user.litellm_bedrock.name
}

output "litellm_bedrock_access_key_id" {
  description = "Access key id for the Bedrock runtime user (→ Vault aws-bedrock-access-key-id)."
  value       = aws_iam_access_key.litellm_bedrock.id
}

output "litellm_bedrock_secret_access_key" {
  description = "Secret for the Bedrock runtime user (→ Vault aws-bedrock-secret-access-key)."
  value       = aws_iam_access_key.litellm_bedrock.secret
  sensitive   = true
}
