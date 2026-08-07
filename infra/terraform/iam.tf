# ---------------------------------------------------------------------------
# The application's AWS identity.
#
# The pod assumes this role through IRSA: the kops cluster publishes an OIDC
# discovery document, the ServiceAccount is annotated with this role's ARN, and
# AWS exchanges the projected ServiceAccount token for short-lived credentials.
#
# Net result: the application has S3 access with NO access keys stored in the
# cluster, no Secret to rotate, and no credential to leak.
# ---------------------------------------------------------------------------

locals {
  # Created only when the cluster's OIDC provider ARN is supplied. Without it
  # there is nothing to trust, so the role would be unusable.
  create_irsa_role = var.oidc_provider_arn != ""

  oidc_issuer = local.create_irsa_role ? replace(
    data.aws_iam_openid_connect_provider.cluster[0].url, "https://", ""
  ) : ""
}

data "aws_iam_openid_connect_provider" "cluster" {
  count = local.create_irsa_role ? 1 : 0
  arn   = var.oidc_provider_arn
}

# --- trust policy ----------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  count = local.create_irsa_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # Scoped to ONE ServiceAccount in ONE namespace. Without this condition any
    # pod in the cluster could assume the role.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${var.service_account_namespace}:${var.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# --- permissions -----------------------------------------------------------

data "aws_iam_policy_document" "s3_access" {
  # Object operations, scoped to the upload prefix rather than the whole
  # bucket. The application has no reason to touch anything else.
  statement {
    sid    = "ReadWriteUploads"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObject",
      # Needed to read the row-count stamped into object metadata.
      "s3:GetObjectAttributes",
    ]

    resources = ["${aws_s3_bucket.csv_uploads.arn}/${var.upload_prefix}/*"]
  }

  # Listing is a BUCKET-level action, so it cannot be scoped by resource ARN.
  # The prefix condition is what confines it to the application's own keys.
  statement {
    sid       = "ListUploadsPrefixOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.csv_uploads.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.upload_prefix}/*"]
    }
  }

  # Objects are SSE-KMS encrypted, so without these the application can write
  # but never read back what it wrote. Decrypt-only: it cannot manage the key.
  statement {
    sid    = "UseTheBucketKey"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]

    resources = [aws_kms_key.csv_uploads.arn]
  }

  # Deliberately NOT granted: s3:DeleteObject (the lifecycle policy handles
  # expiry, the application never needs to delete), s3:PutBucketPolicy,
  # s3:CreateBucket, or anything on the logs bucket.
}

resource "aws_iam_policy" "s3_access" {
  name        = "csv-app-s3-access-${var.environment}"
  description = "Least-privilege S3 access for the csv-app application pods"
  policy      = data.aws_iam_policy_document.s3_access.json
}

resource "aws_iam_role" "app" {
  count = local.create_irsa_role ? 1 : 0

  name               = "csv-app-s3-${var.environment}"
  description        = "Assumed via IRSA by the csv-app ServiceAccount"
  assume_role_policy = data.aws_iam_policy_document.assume_role[0].json

  # An hour is plenty for a web request; the SDK refreshes automatically.
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "app_s3" {
  count = local.create_irsa_role ? 1 : 0

  role       = aws_iam_role.app[0].name
  policy_arn = aws_iam_policy.s3_access.arn
}
