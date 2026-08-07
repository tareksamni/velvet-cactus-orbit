# ---------------------------------------------------------------------------
# The bucket that stores processed CSV uploads, and the Glacier lifecycle
# transition the case study asks for.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "csv_uploads" {
  # checkov:skip=CKV_AWS_144:Cross-region replication doubles storage cost and
  # adds a second region to operate. The lifecycle policy already moves objects
  # to Glacier, and no RPO/RTO requirement was given. Revisit if one is.
  # checkov:skip=CKV2_AWS_62:No event consumer exists — the application lists
  # the bucket directly rather than reacting to notifications (ADR-0005).
  bucket = var.bucket_name

  # Left at the default (false) deliberately: a bucket holding archived
  # business data should not be destroyable by a stray `terraform destroy`
  # while it still has objects in it.
  force_destroy = false
}

# --- ownership & access ----------------------------------------------------

resource "aws_s3_bucket_ownership_controls" "csv_uploads" {
  bucket = aws_s3_bucket.csv_uploads.id

  rule {
    # Disables ACLs entirely; access is governed by bucket and IAM policy only.
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "csv_uploads" {
  bucket = aws_s3_bucket.csv_uploads.id

  # All four, unconditionally. This bucket is never public.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- encryption ------------------------------------------------------------

data "aws_caller_identity" "current" {}

# An explicit key policy, rather than relying on the default. The default gives
# the account root full control and nothing else, which means the S3 log
# delivery service cannot write encrypted access logs.
data "aws_iam_policy_document" "csv_uploads_kms" {
  # These three checks are written for IAM identity policies and misfire on a
  # KMS KEY policy, where `Resource = "*"` is scoped to the key the policy is
  # attached to — there is no ARN to narrow it to, because the key does not
  # have one until it exists. Likewise the kms:* root statement is AWS's
  # documented requirement: without it the key can become unmanageable, and
  # deleting it is then the only recovery.
  # checkov:skip=CKV_AWS_109:Resource "*" in a key policy means this key only.
  # checkov:skip=CKV_AWS_111:Same — the grant is bounded by the key itself.
  # checkov:skip=CKV_AWS_356:A key policy cannot reference its own ARN.
  statement {
    sid    = "AllowAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  # Without this, enabling SSE-KMS on the logs bucket silently stops log
  # delivery: S3 cannot generate a data key and simply drops the records.
  statement {
    sid    = "AllowS3LogDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "csv_uploads" {
  description             = "Encrypts CSV uploads at rest in ${var.bucket_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.csv_uploads_kms.json
}

resource "aws_kms_alias" "csv_uploads" {
  name          = "alias/csv-app-uploads"
  target_key_id = aws_kms_key.csv_uploads.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "csv_uploads" {
  bucket = aws_s3_bucket.csv_uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.csv_uploads.arn
    }
    # Cuts KMS API calls (and cost) dramatically by reusing a data key across
    # objects in the same bucket.
    bucket_key_enabled = true
  }
}

# --- versioning ------------------------------------------------------------

resource "aws_s3_bucket_versioning" "csv_uploads" {
  bucket = aws_s3_bucket.csv_uploads.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

# ---------------------------------------------------------------------------
# LIFECYCLE — the Glacier transition the case study asks for.
#
#   day 0    Standard              millisecond access, highest storage cost
#   day 30   Glacier Instant Retrieval (GLACIER_IR)
#                                  still millisecond access, ~70% cheaper
#   day 90   Glacier Deep Archive  cheapest, 12-48 hour restore
#   day 365  deleted
#
# Why Glacier IR rather than Glacier Flexible Retrieval: the application can
# re-read and re-parse any archived file on demand (GET /files/{key}), and a
# minutes-to-hours restore would break that. Glacier IR keeps reads instant.
#
# COST CAVEAT, stated honestly: Glacier IR bills a 128 KB minimum per object
# and a 90-day minimum storage duration; Deep Archive bills 180 days. The
# sample file is 45 KB, so for objects this small these transitions can cost
# MORE than leaving them in Standard. The mechanism here is correct; whether it
# saves money depends on real object sizes and access patterns. For many small
# objects the right answer is to aggregate them before archiving.
#
# The day counts themselves are invented — no retention policy was given.
# See ASSUMPTIONS.md.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "csv_uploads" {
  bucket = aws_s3_bucket.csv_uploads.id

  # Lifecycle rules on a versioned bucket are only meaningful once versioning
  # is actually configured.
  depends_on = [aws_s3_bucket_versioning.csv_uploads]

  rule {
    id     = "archive-processed-uploads"
    status = "Enabled"

    filter {
      prefix = "${var.upload_prefix}/"
    }

    transition {
      days          = var.days_until_glacier_ir
      storage_class = "GLACIER_IR"
    }

    transition {
      days          = var.days_until_deep_archive
      storage_class = "DEEP_ARCHIVE"
    }

    # Expiration is optional: 0 means keep forever.
    dynamic "expiration" {
      for_each = var.days_until_expiration > 0 ? [1] : []
      content {
        days = var.days_until_expiration
      }
    }
  }

  rule {
    id     = "archive-noncurrent-versions"
    status = var.enable_versioning ? "Enabled" : "Disabled"

    filter {
      prefix = "${var.upload_prefix}/"
    }

    # Superseded versions exist only for accident recovery, so they go straight
    # to the cheapest class rather than following the current-version path.
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    # Failed multipart uploads are invisible in the console but are billed.
    # Without this rule they accumulate forever.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# --- access logging --------------------------------------------------------

resource "aws_s3_bucket" "access_logs" {
  # checkov:skip=CKV_AWS_18:This IS the access-log destination. Pointing its own
  # logs at itself is a recursion, not a control.
  # checkov:skip=CKV_AWS_144:Cross-region replication for 90-day access logs
  # doubles storage cost and adds a second region to manage, for data that is
  # already disposable. Revisit if logs become a compliance artefact.
  # checkov:skip=CKV2_AWS_62:Nothing consumes log-write events.
  bucket = "${var.bucket_name}-logs"
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.csv_uploads.arn
    }
    # Not optional here: S3 server access logging only supports an SSE-KMS
    # destination bucket when S3 Bucket Keys are enabled. Without this, log
    # delivery fails silently.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    # Failed multipart uploads are invisible in the console but still billed.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Versioning is on, so superseded log objects need expiring too or they
  # accumulate forever behind the 90-day expiration above.
  rule {
    id     = "expire-noncurrent-logs"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_logging" "csv_uploads" {
  bucket = aws_s3_bucket.csv_uploads.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "s3-access/"
}

# --- transport security ----------------------------------------------------

data "aws_iam_policy_document" "enforce_tls" {
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.csv_uploads.arn,
      "${aws_s3_bucket.csv_uploads.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "csv_uploads" {
  bucket = aws_s3_bucket.csv_uploads.id
  policy = data.aws_iam_policy_document.enforce_tls.json

  # The public access block must land first, or attaching a bucket policy can
  # be rejected.
  depends_on = [aws_s3_bucket_public_access_block.csv_uploads]
}
