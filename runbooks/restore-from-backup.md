# Runbook: Restore From Backup

**Scope:** Recovering a resource (EBS, RDS/Aurora, DynamoDB, EFS, or S3) from an AWS
Backup recovery point created by this platform — in the primary or the DR region.

**Audience:** On-call engineer or platform operator performing a data recovery.

**Prerequisites:**
- AWS credentials with `backup:StartRestoreJob`, `backup:DescribeRestoreJob`,
  `backup:ListRecoveryPointsByBackupVault`, and the relevant service restore
  permissions, plus `iam:PassRole` for the backup service role.
- The backup service-role ARN (Terraform output `backup_iam_role_arn`).
- Vault names: `backup_vault_primary_name` and `backup_vault_dr_name` (outputs).

> This procedure is the manual counterpart to the automated weekly restore test
> (`runbooks` ↔ `terraform/restore-workflow.tf`). The automation proves backups are
> restorable; this runbook is how a human recovers real data during an incident.

---

## At a glance

| Item | Value |
|------|-------|
| Primary vault | output `backup_vault_primary_name` (e.g. `backup-dr-production-primary`) |
| DR vault | output `backup_vault_dr_name` (e.g. `backup-dr-production-dr`) |
| Primary region | `var.primary_region` (default `us-east-1`) |
| DR region | `var.dr_region` (default `us-west-2`) |
| Backup service role | output `backup_iam_role_arn` |
| Target data RTO | ≤ 4h critical / ≤ 8h standard |

---

## 0. Decide what and from where (target: 5 min)

1. **Identify the resource** and the recovery point you need. Prefer the most recent
   *clean* point. For ransomware/corruption, pick a recovery point from **before** the
   compromise window.
2. **Choose the region.** Restore from the **primary** vault for routine recovery.
   Restore from the **DR** vault when the primary region is impaired (a regional
   outage) — set `--region $DR_REGION` on every command below.
3. **Restore to a NEW resource.** Never restore in place over a live resource. Restore
   to a new volume/instance/table, verify it, then cut over deliberately.

Set environment for the rest of the runbook:

```bash
export PRIMARY_REGION=us-east-1
export DR_REGION=us-west-2
export REGION=$PRIMARY_REGION         # switch to $DR_REGION for cross-region recovery
export VAULT=backup-dr-production-primary   # or ...-dr for the DR vault
export BACKUP_ROLE_ARN=$(terraform -chdir=terraform output -raw backup_iam_role_arn)
```

---

## 1. Find the recovery point (target: 5 min)

```bash
# List recent recovery points in the vault, newest first
aws backup list-recovery-points-by-backup-vault \
  --region "$REGION" \
  --backup-vault-name "$VAULT" \
  --by-created-after "$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-14d +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'sort_by(RecoveryPoints,&CreationDate)[].{Created:CreationDate,Status:Status,RP:RecoveryPointArn,Resource:ResourceArn,Type:ResourceType}' \
  --output table
```

Pick the `RecoveryPointArn` you need and capture its metadata:

```bash
export RP_ARN="arn:aws:...:recovery-point:..."   # from the list above

aws backup get-recovery-point-restore-metadata \
  --region "$REGION" \
  --backup-vault-name "$VAULT" \
  --recovery-point-arn "$RP_ARN" \
  --output json
```

The restore metadata is the template for the `--metadata` you pass to the restore job.
Copy it, then override only what you must (see per-type notes below).

---

## 2. Start the restore job (per resource type)

The exact `--metadata` keys are resource-type specific. Start from the metadata you
fetched in step 1 and adjust.

### EBS volume
```bash
aws backup start-restore-job \
  --region "$REGION" \
  --recovery-point-arn "$RP_ARN" \
  --iam-role-arn "$BACKUP_ROLE_ARN" \
  --resource-type EBS \
  --metadata "volumeType=gp3,availabilityZone=${REGION}a,encrypted=true"
```

### RDS / Aurora
Restoring creates a **new DB instance/cluster** with a new identifier:
```bash
aws backup start-restore-job \
  --region "$REGION" \
  --recovery-point-arn "$RP_ARN" \
  --iam-role-arn "$BACKUP_ROLE_ARN" \
  --resource-type RDS \
  --metadata "DBInstanceIdentifier=restored-$(date +%s),DBInstanceClass=db.t3.medium"
```

### DynamoDB
Restores to a **new table** (the table name must not already exist):
```bash
aws backup start-restore-job \
  --region "$REGION" \
  --recovery-point-arn "$RP_ARN" \
  --iam-role-arn "$BACKUP_ROLE_ARN" \
  --resource-type DynamoDB \
  --metadata "targetTableName=restored-$(date +%s)"
```

### EFS
```bash
aws backup start-restore-job \
  --region "$REGION" \
  --recovery-point-arn "$RP_ARN" \
  --iam-role-arn "$BACKUP_ROLE_ARN" \
  --resource-type EFS \
  --metadata "newFileSystem=true,Encrypted=true,PerformanceMode=generalPurpose,CreationToken=restore-$(date +%s)"
```

### S3
S3 restores recover objects to a target bucket (existing or new):
```bash
aws backup start-restore-job \
  --region "$REGION" \
  --recovery-point-arn "$RP_ARN" \
  --iam-role-arn "$BACKUP_ROLE_ARN" \
  --resource-type S3 \
  --metadata "DestinationBucketName=restored-bucket-$(date +%s),Encrypted=true,NewBucket=true"
```

Capture the returned `RestoreJobId`:
```bash
export RESTORE_JOB_ID="<RestoreJobId from the command output>"
```

---

## 3. Poll the restore job to completion (target: variable)

```bash
watch -n 30 "aws backup describe-restore-job \
  --region $REGION \
  --restore-job-id $RESTORE_JOB_ID \
  --query '{Status:Status,Pct:PercentDone,Message:StatusMessage,Created:CreatedResourceArn}' \
  --output table"
```

Terminal states: `COMPLETED` (success), `FAILED`/`ABORTED` (investigate
`StatusMessage`). Note the `CreatedResourceArn` — that is your restored resource.

---

## 4. Verify integrity (do NOT skip)

Match the automated test's verification intent: confirm the resource exists, is in a
usable state, and contains the data you expect.

```bash
export RESTORED_ARN="<CreatedResourceArn>"
```

- **EBS:** `aws ec2 describe-volumes --region $REGION --volume-ids <vol-id>` → state
  `available`; attach to a throwaway instance and `fsck` / mount read-only to spot-check.
- **RDS/Aurora:** wait for status `available`, then connect and run a row-count / known
  query against a canary table.
- **DynamoDB:** `aws dynamodb describe-table` → `ACTIVE`; `scan --select COUNT` and
  compare against expectations.
- **EFS:** `aws efs describe-file-systems` → `available`; mount and list expected paths.
- **S3:** compare object counts / checksums for a sample of keys.

Record the verification result in the incident ticket.

---

## 5. Cut over (deliberately)

Only after verification:

1. Quiesce writers to the impaired resource if it still exists.
2. Repoint the application (connection string, mount target, table name, volume
   attachment, bucket) to the restored resource. Prefer an IaC change over a console
   edit so state does not drift.
3. Smoke-test the application against the restored data.
4. Resume traffic.

---

## 6. Clean up

- **Delete throwaway artifacts** (test instances used for verification).
- **Do NOT delete** the original recovery points — they remain your safety net (and,
  with vault lock enabled, cannot be deleted before retention anyway).
- **Reconcile Terraform** for any console changes made under pressure.
- If you restored from the DR vault during a regional outage, see
  [`dr-failover.md`](dr-failover.md) for the failback procedure.

---

## Troubleshooting

**`AccessDenied` / `is not authorized to perform: iam:PassRole`.**
You must be allowed to pass the backup service role to AWS Backup. Use the
`backup_iam_role_arn` output and ensure your principal has `iam:PassRole` for it scoped
to `backup.amazonaws.com`.

**Restore job `FAILED` with a KMS error.**
Cross-region restores re-encrypt under the DR-region CMK. Confirm the KMS key policy
allows the backup service principal (it does by default in `backup-vault.tf`) and that
you are operating in the correct region for the vault.

**Recovery point not visible.**
Confirm you are querying the right vault and region. DR copies live in the DR vault
(`backup_vault_dr_name`) in `var.dr_region`, not the primary vault.

**DynamoDB / RDS restore rejected: identifier already exists.**
Restores must target a NEW name. Use a unique `targetTableName` /
`DBInstanceIdentifier` (the examples above append a timestamp).

**It is taking longer than RTO.**
Large volumes/instances take time to hydrate. For critical workloads, restore the
smallest viable point and prefer warm-tier (not cold-storage) recovery points; cold
(archived) recovery points incur a retrieval delay before the restore can start.
