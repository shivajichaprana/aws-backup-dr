# Architecture — aws-backup-dr

## Overview

This project implements a defence-in-depth backup and disaster recovery strategy using AWS-native services. The design is cloud-agnostic in approach but AWS-native in implementation, following the AWS Backup best-practice framework.

## Design Principles

1. **Immutability** — Backup vaults use compliance-mode vault lock so recovery points cannot be deleted before retention expiry, even by an account root user. This is the primary defence against ransomware.

2. **Encryption at rest** — Every recovery point is encrypted with a dedicated KMS Customer Managed Key (CMK). The key policy allows only AWS Backup service and the account root to use the key.

3. **Geographic separation** — All backups are automatically copied cross-region (primary → DR) to protect against regional outages.

4. **Automated verification** — Weekly restore tests confirm that backups are actually restorable, not just that the backup job completed.

5. **Observability** — CloudWatch alarms + SNS notifications surface failures within minutes.

## Component Map

```
┌────────────────────────────────────────────────────────────────────────┐
│ Terraform Modules                                                       │
│                                                                         │
│  backup-vault.tf         backup-plan.tf          backup-selection.tf   │
│  ┌─────────────────┐     ┌────────────────┐      ┌──────────────────┐  │
│  │ KMS CMK         │     │ Standard Plan  │      │ Tag: Backup=true │  │
│  │ Primary vault   │◀────│ Critical Plan  │◀─────│ Tag: critical    │  │
│  │ DR vault        │     │ Schedule/rules │      │ Explicit ARNs    │  │
│  │ Vault lock      │     │ Lifecycle      │      └──────────────────┘  │
│  │ SNS alerts      │     │ Cross-region   │                             │
│  └─────────────────┘     └────────────────┘                             │
└────────────────────────────────────────────────────────────────────────┘
```

## Backup Tiers

| Tier     | Schedule        | Retention (Primary) | Retention (DR) | Use Case                    |
|----------|-----------------|--------------------|-----------------|-----------------------------|
| Critical | Hourly (08-20Z) + Daily | 365 days   | 30 days         | Databases, critical apps    |
| Standard | Daily 05:00Z + Weekly   | 365 days   | 90 days         | General compute + storage   |

## Vault Lock (Compliance Mode)

AWS Backup vault lock in compliance mode provides WORM (Write Once Read Many) semantics:

- Once the grace period (`changeable_for_days`, minimum 3 days) expires, the lock settings **cannot be modified or removed** — not even by the root account.
- Recovery points cannot be deleted before `min_retention_days` expires.
- Recovery points cannot be retained beyond `max_retention_days` (automatically deleted).

**Activation:** `enable_vault_lock = false` by default. Set to `true` only after validating retention settings in a test environment.

## Encryption Architecture

```
Backup Job
    │
    ├─── Primary Region ──▶ KMS CMK (alias/backup-dr-primary) ──▶ Encrypted Recovery Point
    │                         └─── Key rotation: annual (automatic)
    │
    └─── DR Region ────────▶ KMS CMK (alias/backup-dr-dr) ──▶ Encrypted DR Copy
                              └─── Key rotation: annual (automatic)
```

Each CMK is confined to its region. Cross-region copy re-encrypts under the destination key.

## IAM Design

A single `backup-dr-production-backup-role` IAM role is assumed by the AWS Backup service. It carries:

- `AWSBackupServiceRolePolicyForBackup` — permissions to create recovery points across all supported resource types
- `AWSBackupServiceRolePolicyForRestores` — permissions to restore from recovery points
- Inline policy for S3 backup (additional S3 GetObject permissions)
- Inline policy for KMS cross-region operations

## Monitoring

| Alarm | Trigger | Action |
|-------|---------|--------|
| `backup-job-failures` | Any job FAILED/ABORTED/EXPIRED | SNS → email/Slack |
| `no-backup-completions` | 0 completions in 24h | SNS → email/Slack |
| EventBridge rule | Job state change (FAILED) | SNS topic |

## Adding a New Service

1. Tag the resource: `Backup=true` (standard) or `Backup=true` + `BackupTier=critical`
2. Wait for the next backup window — no Terraform changes needed
3. Verify in the AWS Backup console → Protected resources
