# ---------------------------------------------------------------------------
# Provider and backend configuration.
#
# DELIBERATELY UNBOUND. There are no credentials, no profile, no assumed role
# and no configured backend, because this configuration has never been applied
# against a real AWS account and is not intended to be from this repository.
# See ../../docs/adr/0003-terraform-not-bound-to-aws-account-oidc.md.
#
# It is statically validated only:
#   terraform fmt -check
#   terraform init -backend=false
#   terraform validate
#
# That works precisely because no backend and no credentials are configured.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # --- remote state (commented: no bucket exists) -------------------------
  # State must never live on a laptop. In a real deployment:
  #
  # backend "s3" {
  #   bucket       = "csv-app-tfstate-<globally-unique>"
  #   key          = "csv-app/s3/terraform.tfstate"
  #   region       = "eu-west-1"
  #   encrypt      = true
  #   use_lockfile = true   # S3-native locking; supersedes the DynamoDB table
  # }
}

provider "aws" {
  region = var.region

  # --- how this would really authenticate ---------------------------------
  # No static access keys, anywhere, ever. Terraform Cloud (or GitHub Actions)
  # presents a short-lived OIDC token, which AWS exchanges for temporary
  # credentials against a scoped deployment role:
  #
  # assume_role_with_web_identity {
  #   role_arn                = "arn:aws:iam::<account-id>:role/terraform-deploy"
  #   session_name            = "csv-app-terraform"
  #   web_identity_token_file = "/path/to/token"  # injected by TFC / GH OIDC
  # }
  #
  # The trust policy on that role restricts which repository and which branch
  # may assume it, so a fork or a feature branch cannot deploy to production.
  # The role itself holds only the permissions needed to manage the resources
  # in this configuration — see iam.tf for the application's own role, which
  # is narrower still.

  default_tags {
    tags = {
      Project     = "csv-app"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "csv-app"
    }
  }
}
