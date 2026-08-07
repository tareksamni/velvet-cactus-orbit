output "bucket_name" {
  description = "Name of the uploads bucket. Set this as s3.bucket in charts/csv-app/values-prod.yaml."
  value       = aws_s3_bucket.csv_uploads.id
}

output "bucket_arn" {
  description = "ARN of the uploads bucket."
  value       = aws_s3_bucket.csv_uploads.arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting the bucket."
  value       = aws_kms_key.csv_uploads.arn
}

output "app_role_arn" {
  description = <<-EOT
    ARN of the IRSA role the application assumes. Set this as
    serviceAccount.annotations."eks.amazonaws.com/role-arn" in
    charts/csv-app/values-prod.yaml. Empty when no OIDC provider was supplied.
  EOT
  value       = local.create_irsa_role ? aws_iam_role.app[0].arn : ""
}

output "s3_policy_arn" {
  description = "ARN of the least-privilege S3 policy, for attaching to another principal if needed."
  value       = aws_iam_policy.s3_access.arn
}

output "lifecycle_summary" {
  description = "Human-readable summary of the archive policy, so a reviewer can see it without reading the plan."
  value = join(" -> ", compact([
    "Standard",
    "day ${var.days_until_glacier_ir}: GLACIER_IR",
    "day ${var.days_until_deep_archive}: DEEP_ARCHIVE",
    var.days_until_expiration > 0 ? "day ${var.days_until_expiration}: deleted" : "retained indefinitely",
  ]))
}
