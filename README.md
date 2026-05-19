# aws-backup-dr

Cross-region AWS Backup framework with immutable vault, restore testing, and Route 53 failover.

## Overview

This project provisions a production-grade AWS Backup and disaster recovery platform covering:

- **Immutable Backup Vaults** — KMS-encrypted, compliance-mode vault lock preventing deletion before retention expiry
- **Tag-based Backup Plans** — Daily backups for EBS, RDS, EFS, DynamoDB, and S3 with cross-region copy
- **Automated Restore Testing** — Weekly Lambda + Step Functions pipeline that verifies backup integrity
- **DNS Failover** — Route 53 health-check-driven failover routing between primary and DR regions

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Primary Region (us-east-1)         DR Region (us-west-2)       │
│                                                                  │
│  ┌──────────────────────┐           ┌──────────────────────┐    │
│  │  Resources tagged    │           │  Cross-region copy   │    │
│  │  Backup=true         │──backup──▶│  vault (immutable)   │    │
│  │  EBS, RDS, EFS,      │           │                      │    │
│  │  DynamoDB, S3        │           └──────────────────────┘    │
│  └──────────────────────┘                      │                 │
│           │                           weekly restore test        │
│           ▼                                    ▼                 │
│  ┌──────────────────────┐           ┌──────────────────────┐    │
│  │  Backup Vault        │           │  Lambda + Step Fn    │    │
│  │  (vault lock,        │           │  restore → verify    │    │
│  │   KMS CMK)           │           │  → teardown          │    │
│  └──────────────────────┘           └──────────────────────┘    │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Route 53 Failover Routing                               │   │
│  │  Primary health check ──fail──▶ DR endpoint              │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## RPO / RTO Targets

| Tier       | RPO    | RTO     |
|------------|--------|---------|
| Critical   | 1 hour | 4 hours |
| Standard   | 24 hrs | 8 hours |
| Archive    | 24 hrs | 48 hrs  |

## Quick Start

```bash
# 1. Configure provider variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit with your account IDs, regions, KMS key settings

# 2. Initialize and apply
cd terraform
terraform init
terraform plan
terraform apply

# 3. Tag resources for backup
aws ec2 create-tags --resources vol-xxxxxx --tags Key=Backup,Value=true Key=BackupTier,Value=critical
```

## Module Reference

| Module | Description |
|--------|-------------|
| `terraform/backup-vault.tf` | KMS-encrypted backup vault with compliance-mode vault lock |
| `terraform/backup-plan.tf` | Backup rules: daily schedule, lifecycle, cross-region copy |
| `terraform/backup-selection.tf` | Tag-based resource selection (`Backup=true`) |

## Directory Structure

```
aws-backup-dr/
├── terraform/              # Infrastructure-as-code
│   ├── backup-vault.tf     # Backup vault + KMS CMK
│   ├── backup-plan.tf      # Backup plans and rules
│   ├── backup-selection.tf # Tag-based resource selection
│   ├── variables.tf        # Input variables
│   ├── outputs.tf          # Output values
│   ├── versions.tf         # Provider version constraints
│   └── data.tf             # Data sources
├── lambda/
│   ├── restore-tester/     # Automated restore test Lambda
│   └── backup-reporter/    # Weekly backup status reporter
├── scripts/                # Helper shell scripts
├── runbooks/               # DR runbook documentation
├── docs/                   # Architecture and strategy docs
└── .github/workflows/      # CI pipelines
```

## Prerequisites

- Terraform >= 1.5
- AWS provider >= 5.0
- AWS CLI configured with appropriate permissions
- IAM permissions: `backup:*`, `kms:*`, `iam:CreateRole`, `route53:*`

## Contributing

Open a Discussion in the repo or comment on the PR.

## License

MIT License — see [LICENSE](LICENSE).
