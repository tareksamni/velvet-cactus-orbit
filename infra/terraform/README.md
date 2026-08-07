# Terraform — S3 bucket and Glacier lifecycle

## This has never been applied

**This configuration has never been run against a real AWS account. No bucket,
KMS key, IAM role or policy defined here has ever been created.**

There is no configured provider credential, no assumed role, and no remote state
backend. It is a demonstration of the implementation, written for a DevOps
interview assignment (see [`ASSUMPTIONS.md`](../../ASSUMPTIONS.md) and
[ADR-0003](../../docs/adr/0003-terraform-not-bound-to-aws-account-oidc.md)).

What *is* verified:

```console
$ terraform fmt -check      # formatting
$ terraform init -backend=false
$ terraform validate
Success! The configuration is valid.
```

That proves the configuration is syntactically valid, type-correct, and
internally consistent. It proves **nothing** about how AWS responds to it.

### So expect runtime errors on a first real apply

This is normal for any never-applied configuration, and each of these is a
small, local fix — Terraform reports the exact resource and the AWS API error:

| Likely error | Cause | Fix |
|---|---|---|
| `BucketAlreadyExists` | S3 bucket names are globally unique across all AWS accounts, and `var.bucket_name` still says `REPLACE-ME` | Set a unique `bucket_name` |
| `AccessDenied` on any resource | The deploy role lacks a permission | Add it to the deployment role's policy |
| `InvalidArgument` on the lifecycle rule | Region or provider-version differences in accepted storage-class transitions | Adjust the transition days/classes |
| `NoSuchEntity` on the OIDC provider | `oidc_provider_arn` points at a provider that does not exist yet | Create the cluster first, or leave the variable empty to skip the IRSA role |
| Denied by an SCP or guardrail | Org-level policy blocks unencrypted buckets, certain regions, or IAM role creation | Work with whoever owns the org policy |

Budget a little time for a first apply rather than assuming it lands clean.
"Validates cleanly" is not the same as "applied successfully", and this README
would rather say so than imply otherwise.

## First real apply — checklist

1. **Name the bucket.** Set `bucket_name` to something globally unique.
   The `-logs` bucket derives from it, so both must be free.
2. **Choose the region** via `region` (default `eu-west-1`).
3. **Decide the retention policy.** The lifecycle day counts
   (30 → Glacier IR, 90 → Deep Archive, 365 → expire) are **invented** — no
   retention requirement was given with the case study. Confirm them with
   whoever owns the data before applying.
4. **Wire authentication.** Uncomment the `assume_role_with_web_identity`
   block in `providers.tf` and point it at an IAM role whose trust policy
   permits your CI's OIDC identity. No static access keys.
5. **Configure remote state.** Uncomment the `backend "s3"` block and point it
   at a versioned, encrypted state bucket. State must not live on a laptop.
6. **Supply the cluster's OIDC provider ARN** as `oidc_provider_arn` so the
   IRSA role is created. Leave it empty and the role is skipped — useful for a
   first apply of just the bucket.
7. **Plan and read it.** `terraform plan` — check the bucket name, the
   lifecycle transitions, and that nothing unexpected is being destroyed.
8. **Apply**, then copy the outputs into `charts/csv-app/values-prod.yaml`:
   `bucket_name` → `s3.bucket`, `app_role_arn` →
   `serviceAccount.annotations."eks.amazonaws.com/role-arn"`.

## What this creates

| Resource | Purpose |
|---|---|
| `aws_s3_bucket.csv_uploads` | Stores processed CSV uploads |
| `aws_s3_bucket_lifecycle_configuration.csv_uploads` | **The Glacier transition** — the case-study requirement |
| `aws_kms_key.csv_uploads` | SSE-KMS encryption at rest, with rotation |
| `aws_s3_bucket_versioning` | Protects against accidental overwrite/delete |
| `aws_s3_bucket_public_access_block` | All four blocks on; never public |
| `aws_s3_bucket_policy.csv_uploads` | Denies any non-TLS request |
| `aws_s3_bucket.access_logs` | Access logs, expired after 90 days |
| `aws_iam_role.app` + `aws_iam_policy.s3_access` | Least-privilege IRSA identity for the pods |

## The lifecycle policy

```
day 0    Standard                    millisecond access
day 30   GLACIER_IR                  millisecond access, ~70% cheaper
day 90   DEEP_ARCHIVE                cheapest, 12–48h restore
day 365  deleted

noncurrent versions:  day 30 -> GLACIER, day 90 -> deleted
incomplete multipart uploads: aborted after 7 days
```

**Glacier Instant Retrieval, not Glacier Flexible Retrieval**, because the
application can re-read and re-parse any archived file on demand
(`GET /api/v1/files/{key}`) and a minutes-to-hours restore would break that.

**Cost caveat, stated honestly:** Glacier IR bills a 128 KB minimum per object
and a 90-day minimum storage duration; Deep Archive bills 180 days. The sample
file is 45 KB. For objects this small these transitions can cost *more* than
leaving them in Standard. The mechanism is correct; whether it saves money
depends on real object sizes and access patterns. At scale the better answer is
to aggregate small objects before archiving.
