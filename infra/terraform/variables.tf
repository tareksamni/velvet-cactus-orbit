variable "region" {
  description = "AWS region for the bucket and IAM resources."
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Environment name, used in tags and the bucket name."
  type        = string
  default     = "prod"
}

variable "bucket_name" {
  description = <<-EOT
    Name of the bucket that stores processed CSV uploads.

    S3 bucket names are GLOBALLY unique across all AWS accounts, so this
    default WILL collide on a first real apply and must be changed. It is the
    single most likely cause of an apply-time failure here.
  EOT
  type        = string
  default     = "csv-app-uploads-REPLACE-ME"
}

variable "upload_prefix" {
  description = "Key prefix the application writes under. The lifecycle rules and the IAM policy are both scoped to it."
  type        = string
  default     = "uploads"
}

# --- lifecycle policy ------------------------------------------------------
# These day counts are INVENTED. No retention policy was supplied with the case
# study, so they represent a plausible archive policy, not a requirement.
# See ASSUMPTIONS.md — this is the number most likely to be wrong, and it is a
# one-line change.

variable "days_until_glacier_ir" {
  description = "Days in Standard before transitioning to Glacier Instant Retrieval."
  type        = number
  default     = 30

  validation {
    # S3 rejects a transition to Glacier IR earlier than 30 days.
    condition     = var.days_until_glacier_ir >= 30
    error_message = "S3 requires at least 30 days before a Glacier Instant Retrieval transition."
  }
}

variable "days_until_deep_archive" {
  description = "Days in Standard before transitioning to Glacier Deep Archive."
  type        = number
  default     = 90
}

variable "days_until_expiration" {
  description = "Days before the object is deleted outright. Set to 0 to keep objects forever."
  type        = number
  default     = 365
}

variable "noncurrent_version_expiration_days" {
  description = "Days before a superseded version is deleted."
  type        = number
  default     = 90
}

variable "enable_versioning" {
  description = "Keep previous versions of an object. Protects against accidental overwrite and deletion."
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = <<-EOT
    ARN of the cluster's IAM OIDC provider, used to let the application's
    Kubernetes ServiceAccount assume an AWS role (IRSA) with no static keys.
    kops creates this when serviceAccountIssuerDiscovery is enabled — see
    infra/kops/cluster.yaml.
  EOT
  type        = string
  default     = ""
}

variable "service_account_namespace" {
  description = "Kubernetes namespace of the application's ServiceAccount."
  type        = string
  default     = "csv-app"
}

variable "service_account_name" {
  description = "Name of the application's Kubernetes ServiceAccount."
  type        = string
  default     = "csv-app"
}
