# Disaster Recovery Strategy — aws-backup-dr

This document describes *how* this platform delivers disaster recovery: the threat
model it defends against, the recovery tiers and their RPO/RTO targets, the failure
scenarios it is designed to survive, and the operational rituals that keep it
trustworthy. The mechanics of each component live in
[`architecture.md`](architecture.md); the step-by-step recovery procedures live in
[`../runbooks/`](../runbooks/).

---

## 1. Threat model

The platform is designed to survive, in increasing order of severity:

| # | Scenario | Primary defence |
|---|----------|-----------------|
| 1 | Accidental deletion / corruption of a single resource | Tag-based daily/hourly recovery points |
| 2 | Operator error deleting a backup plan or vault | IAM permission boundary blocking destructive ops |
| 3 | Ransomware / malicious deletion of recovery points | Compliance-mode vault lock (WORM) |
| 4 | Loss of an Availability Zone | Multi-AZ source resources + AWS Backup durability |
| 5 | Loss of an entire AWS region | Cross-region backup copy + Route 53 DNS failover |
| 6 | Compromise of the production account | Optional cross-account copy into an isolated DR account |

## 2. Recovery tiers

Workloads are classified by tagging, not by separate infrastructure:

| Tier | Tag(s) | RPO | RTO | Typical workloads |
|------|--------|-----|-----|-------------------|
| **Critical** | `Backup=true`, `BackupTier=critical` | ≤ 1 hour | ≤ 4 hours | Transactional databases, payment systems, primary datastores |
| **Standard** | `Backup=true` | ≤ 24 hours | ≤ 8 hours | Application servers, content stores, internal tools |
| **Archive** | (long-retention recovery points) | ≤ 24 hours | ≤ 48 hours | Compliance/audit data retrieved rarely |

> **RPO** is bounded by the cadence of the most recent recovery point. The critical
> tier's hourly window (08:00–20:00 UTC) gives a sub-hour RPO during business hours and
> a 24-hour RPO overnight via the daily rule. **RTO** is bounded by restore-job
> duration (data tier) or DNS propagation + DR warm-up (service tier).

## 3. DR topology

- **Primary region:** `us-east-1` (default; `var.primary_region`).
- **DR region:** `us-west-2` (default; `var.dr_region`).
- **Backup replication:** every plan rule has a `copy_action` to the DR vault, so
  recovery points exist in both regions within minutes of creation.
- **Service failover:** active-passive via Route 53 failover records. The DR
  environment is expected to run **warm-standby** (scaled down) and scale up on
  failover.
- **Optional account isolation:** `cross-account-copy.tf` can copy recovery points into
  a vault owned by a separate DR account, so a full compromise of the production
  account cannot reach the backups.

## 4. Failure scenarios & responses

### 4.1 Single-resource loss or corruption
Restore the most recent (or a point-in-time) recovery point for that resource. Follow
[`../runbooks/restore-from-backup.md`](../runbooks/restore-from-backup.md). No regional
failover needed.

### 4.2 Backup-plan / vault tampering
The permission boundary blocks deletion attempts and the EventBridge job-state rule
surfaces anomalies. If the break-glass role was used, reconcile state and review the
CloudTrail trail in the post-incident review.

### 4.3 Ransomware
With vault lock enabled, encrypted-and-ransom scenarios cannot destroy your recovery
points: they are immutable until retention expiry. Recover the last clean recovery
point (chosen from before the compromise window) per the restore runbook.

### 4.4 Regional outage
1. Route 53 health checks detect the primary endpoint failure within
   `failure_threshold × request_interval` (default 90s) and answer with the DR record.
2. The on-call engineer follows
   [`../runbooks/dr-failover.md`](../runbooks/dr-failover.md): confirm the outage, scale
   DR to full load, promote the data tier (restore from the latest DR-region recovery
   point if needed), and communicate.
3. On recovery, the primary health check flips healthy and Route 53 fails back
   automatically.

## 5. RPO/RTO accounting

RPO and RTO are not aspirations — they are derived from concrete settings:

```
RPO(critical) = max gap between recovery points
              = 1 hour during 08:00-20:00Z, else up to 24h (daily rule)

RPO(standard) = 24 hours (daily rule)

RTO(service)  = health-check detection (≈90s)
              + record TTL expiry (alias managed TTL, typically ≤60s)
              + DR scale-up time   (workload-specific)
              ≈ target ≤ 15 minutes to healthy DR responses

RTO(data)     = restore-job duration (resource-size dependent)
              + verification
              ≈ target ≤ 4h (critical) / ≤ 8h (standard)
```

Continuous restore testing measures the *data* RTO empirically every week; DR
DR drills (below) measure the *service* RTO.

## 6. Vault lock rollout

Vault lock is irreversible once its grace period expires, so it ships **disabled**
(`enable_vault_lock = false`). Roll it out deliberately:

1. **Validate retention** in a non-production environment. Confirm
   `vault_lock_min_retention_days` (default 35) and `vault_lock_max_retention_days`
   (default 365) match your compliance and cost requirements.
2. **Enable in production** by setting `enable_vault_lock = true`. The lock starts in a
   *changeable* state for `changeable_for_days` (default 3, AWS minimum).
3. **Use the grace period** to confirm no legitimate workflow needs to delete recovery
   points sooner than the minimum retention. You can still adjust during this window.
4. **Let it become permanent.** After the grace period, the lock is immutable. Document
   the lock date in your runbook and change-management record.

> Do **not** enable vault lock and `prevent_destroy` together in a sandbox you intend to
> tear down — the recovery points (and their cost) will persist until retention expiry.

## 7. Operational rituals

| Ritual | Cadence | Owner | Evidence |
|--------|---------|-------|----------|
| Automated restore test | Weekly (Sun 03:00Z) | Platform | `BackupDR/RestoreTesting` metrics, SNS report |
| Backup-status report | Weekly (Mon 08:00Z) | Platform | SNS summary, `BackupDR/Reporting` metrics |
| DR failover drill | Quarterly | Platform + service owner | Drill report, RTO measurement |
| Vault-lock & retention review | Annually | Security + Platform | Reviewed `terraform.tfvars` |
| Runbook review | After every incident | On-call | Updated runbooks |

## 8. Assumptions & out-of-scope

- Source resources are themselves multi-AZ where their service supports it; this
  platform protects *data*, not single-AZ compute topology.
- The DR-region application stack (compute, networking, config) is provisioned and kept
  warm by the owning service's own IaC — this repo provides backups and DNS failover,
  not the DR application itself.
- Database-specific point-in-time recovery (e.g. RDS PITR) complements, and is not
  replaced by, AWS Backup recovery points.
