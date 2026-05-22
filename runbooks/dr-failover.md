# Runbook: DNS Failover to the DR Region

**Scope:** Application endpoint served by the Route 53 failover records defined in
`terraform/route53-failover.tf`, with health checks and alarms from
`terraform/health-checks.tf`.

**Audience:** On-call engineer responding to a primary-region outage.

**Failover model:** Active–passive. Route 53 normally answers with the PRIMARY
alias (active region). When the primary health check reports Unhealthy, Route 53
automatically answers with the SECONDARY (DR-region) alias. **The DNS swap is
automatic — most of this runbook is about confirming, accelerating, and recovering
from that swap, not performing it by hand.**

---

## At a glance

| Item | Value |
|------|-------|
| Failover record | `var.failover_record_name` (output `failover_record_fqdn`) |
| Primary health check | output `primary_health_check_id` |
| Secondary health check | output `secondary_health_check_id` |
| Alarm topic (us-east-1) | output `dns_failover_alerts_topic_arn` |
| Triggering alarm | `<name_prefix>-primary-endpoint-unhealthy` |
| Early-warning alarm | `<name_prefix>-primary-endpoint-high-latency` |
| Target RTO | 15 minutes to healthy DR responses |
| Target RPO | Per backup plan — see `docs/dr-strategy.md` |

> Health-check metrics and alarms live in **us-east-1** regardless of the app
> region. When using the console, switch the region selector to **N. Virginia
> (us-east-1)** for anything under Route 53 → Health checks → Monitoring.

---

## 1. Detect & confirm (target: 5 min)

You were likely paged by the `*-primary-endpoint-unhealthy` alarm.

1. **Confirm it is real, not a checker false-positive.**
   - Route 53 console → Health checks → select the primary check → **Health
     checkers** tab. Confirm a majority of regions report **Unhealthy** (a single
     region failing is usually a network blip, not an outage).
   - Independently probe the endpoint:
     ```bash
     curl -sS -o /dev/null -w "%{http_code} %{time_total}s\n" \
       "https://<primary_health_check_fqdn>/health"
     ```
2. **Check the DR endpoint is healthy** (you are about to send all traffic there):
   - Route 53 console → Health checks → secondary check → expect **Healthy**.
   - If the `*-dr-endpoint-unhealthy` alarm is ALSO firing, escalate immediately —
     there is no healthy target. Jump to §5.
3. **Decide:** if the primary outage is confirmed and DR is healthy, proceed.
   No action is required to *start* failover — Route 53 is already doing it.

---

## 2. Verify automatic failover is happening (target: 5 min)

1. **Confirm what Route 53 is currently answering** (bypass local cache by
   querying an authoritative name server for the zone):
   ```bash
   # Resolve directly against a Route 53 name server for the zone
   AUTHNS=$(dig +short NS <zone-apex> | head -1)
   dig +norecurse @"$AUTHNS" <failover_record_name> A
   ```
   You should see the **DR** alias target's addresses, not the primary's.
2. **Confirm clients can reach DR through the record:**
   ```bash
   curl -sS -o /dev/null -w "%{http_code}\n" "https://<failover_record_name>/health"
   ```
   Expect `200`.
3. If DNS still returns the primary target after a few minutes, see
   *Troubleshooting → "Failover not switching"* below.

---

## 3. Reduce client-side cache delay (if not already low)

Clients keep resolving the old answer until the record's TTL expires. Alias
records to AWS targets use a managed TTL, but if you have plain (non-alias)
records elsewhere in the path, a high TTL slows propagation.

- For a planned event, **lower the TTL well in advance** (e.g. to 60s) so a
  later failover propagates quickly.
- During an unplanned event you cannot retroactively shorten a TTL that clients
  already cached — you can only wait it out. Note the configured TTL and set
  expectations accordingly.

---

## 4. Stabilise in DR & communicate

1. **Scale the DR environment** to handle full production load (it may be sized
   for warm-standby). Confirm autoscaling has caught up before declaring stable.
2. **Promote data tier** if applicable (e.g. promote the cross-region read
   replica to primary, or restore from the latest recovery point — see
   `runbooks/restore-from-backup.md`).
3. **Post status** in the incident channel and on the public status page:
   - Time failover started, current customer impact, the fact that traffic is
     now served from the DR region, and the next update time.
4. **Open/Update the incident ticket** with the alarm name, health-check IDs, and
   a link to this runbook.

---

## 5. If BOTH endpoints are unhealthy (no healthy target)

This is a sev-1 full outage.

1. Escalate to the secondary on-call and the service owner immediately.
2. Determine whether the cause is shared (e.g. a global dependency, an expired
   ACM cert, a bad config push to both regions, a DNS/registrar issue) rather
   than region-local.
3. If the primary region is actually recoverable faster than DR, focus recovery
   there. Route 53 will automatically return traffic to primary once its health
   check goes Healthy.
4. Do not disable the health checks to "force" an answer — that points clients at
   a dead endpoint with no automatic recovery.

---

## 6. Manual override (rare — use with care)

Automatic failover should not normally be overridden. Only do this when you must
force traffic to a specific region (e.g. a confirmed bad-but-"healthy" primary).

- **Force traffic to DR:** in Route 53, temporarily set the **primary** failover
  record's health check to one that is intentionally Unhealthy, or disable the
  primary record. Prefer doing this through Terraform (set
  `enable_dns_failover` workflow inputs) so state does not drift; for an
  emergency console change, **record it** and reconcile Terraform afterwards.
- **Pin traffic to primary** (suppress failover): not recommended during an
  incident — it removes your safety net.

> Any out-of-band console change MUST be reconciled back into Terraform during
> the post-incident cleanup, or the next `terraform apply` will revert it.

---

## 7. Fail back to primary (after recovery)

1. Confirm the primary region is fully healthy: dependencies, data tier, and a
   manual `curl https://<primary_health_check_fqdn>/health` returning `200`.
2. The primary Route 53 health check will flip to **Healthy** on its own once
   probes succeed (`failure_threshold` × `request_interval` seconds).
3. Route 53 then automatically resumes answering with the PRIMARY record — **no
   manual DNS change required.** Watch the `*-primary-endpoint-unhealthy` alarm
   return to **OK**.
4. Verify with the §2 `dig` command that the record now resolves to the primary
   target again.
5. Scale the DR environment back down to warm-standby once primary is confirmed
   stable, and demote any promoted data-tier resources as appropriate.

---

## 8. Post-incident

- Confirm any emergency console changes were reverted/reconciled in Terraform.
- Re-verify both health checks are Healthy and all three failover alarms are OK.
- Capture timeline, detection-to-failover duration vs RTO, and action items in
  the incident review.
- If failover was slow, review TTLs and `health_check_failure_threshold` /
  `health_check_request_interval` for tuning.

---

## Troubleshooting

**Failover not switching to DR.**
- The primary health check may still read Healthy — confirm in the console's
  Health checkers tab. `evaluate_target_health` on the alias can keep the record
  "up" if the target group still has healthy members even though the app is
  broken; tighten the explicit health-check path (`/health`) to test real
  application health.
- You may be reading a cached resolver answer. Re-run the §2 `dig` against an
  authoritative name server, not your local resolver.

**Alarm in INSUFFICIENT_DATA.**
- Health-check metrics only exist in us-east-1 — confirm you are looking there.
- A brand-new health check needs a few minutes of probe data before metrics
  appear; `treat_missing_data = "breaching"` means the alarm errs on the side of
  failing over, which is intentional.

**`curl` to the record works but the app is broken.**
- The health-check path returned 2xx/3xx but the application is degraded. Make
  the `/health` endpoint a real readiness check (dependencies, DB connectivity)
  so it fails when the app cannot serve traffic.

**Need to test failover safely.**
- Use a non-production `failover_record_name`, then make the primary
  `primary_health_check_fqdn` return non-2xx (e.g. stop the primary task or block
  the health path) and watch DNS swap. Restore and watch it fail back.
