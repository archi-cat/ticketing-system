# TLS certificate rotation runbook

How the Gateway TLS certificate is renewed, how to verify it after rotation, and how to recover when renewal goes wrong.

Background design lives in [ADR-0020](decisions/0020-gateway-tls-termination.md).

## How auto-renewal works

The certificate is issued by Let's Encrypt with a **90-day** validity. cert-manager triggers renewal at **~2/3 of lifetime** — roughly **day 60** — automatically. No human intervention is needed for a healthy rotation.

The renewal flow on day ~60:

1. cert-manager's controller sees `notAfter - now < renewBefore` on the `Certificate` resource (default `renewBefore` = 1/3 of lifetime ≈ 30 days).
2. It creates a fresh `CertificateRequest`, which the production `ClusterIssuer` processes through the same ACME DNS-01 flow used at first issuance:
   - DuckDNS webhook updates the TXT record at `_acme-challenge.<fqdn>`
   - Let's Encrypt validates the TXT
   - Cert is issued and stored back into the K8s `Secret` `cert-manager/ticketing-tls`
3. ESO's `PushSecret` mirrors the new `tls.crt` and `tls.key` into Key Vault as `ticketing-tls-crt` and `ticketing-tls-key` (KV archive — AGC reads the K8s Secret directly).
4. AGC's data plane picks up the new Secret content within seconds — no Gateway re-apply needed.

## What to monitor (passive)

Nothing on the live cluster requires watching every day. Two long-running signals are enough:

- **Cert-expiry alert** (Phase 3 Tier 1 #3) — fires at `30 days remaining`. If the alert fires, it means renewal failed and the cert is now within the renewal window without having been refreshed.
- **Let's Encrypt expiry email** — sent to the address configured as `ACME_EMAIL`. Triggers at 20 days and 10 days remaining.

If neither fires, the cert is rotating correctly.

## Health check (anytime)

```bash
# Cert is Ready, what's the issuer + expiry?
kubectl get certificate -n cert-manager ticketing-tls
kubectl describe certificate -n cert-manager ticketing-tls | grep -E 'Not Before|Not After|Renewal Time'

# Same info from the served cert (proves what browsers actually see)
openssl s_client -connect <duckdns-fqdn>:443 -servername <duckdns-fqdn> </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

Expected:

- `Issuer = Let's Encrypt` (no `(STAGING)` prefix)
- `Not After` is ~30+ days in the future under normal conditions
- `Renewal Time` (cert-manager status) sits ~30 days before `Not After`

## Force a manual renewal

Useful when:

- You changed the cert's `dnsNames` and want the new SANs live immediately
- You're testing the rotation flow
- An automated renewal hung partway through and you want a clean retry

```bash
# Modern way (cert-manager CLI plugin)
kubectl cert-manager renew -n cert-manager ticketing-tls

# Manual fallback if the plugin isn't installed:
# Add an annotation that triggers an immediate reconcile
kubectl annotate certificate -n cert-manager ticketing-tls \
  cert-manager.io/issue-temporary-certificate="true" --overwrite
```

After triggering, watch the renewal chain:

```bash
# Should see a new CertificateRequest, Order, and Challenge progress to Ready
kubectl get certificaterequest,order,challenge -n cert-manager -w
```

Once the new `Secret` content lands, AGC's data plane picks it up within seconds. Confirm with:

```bash
echo | openssl s_client -connect <duckdns-fqdn>:443 -servername <duckdns-fqdn> 2>/dev/null \
  | openssl x509 -noout -dates
```

`Not Before` should be within the last few minutes.

## Recovering from a failed renewal

The failure modes are the same as first-issuance failures. The events on the `Certificate` and downstream `CertificateRequest` / `Order` / `Challenge` are the diagnostic source of truth.

```bash
kubectl describe certificate -n cert-manager ticketing-tls
kubectl get certificaterequest,order,challenge -n cert-manager
```

Walk **down** the chain until you find the first resource that is `False` or stuck `Pending`. Common stuck-states and fixes:

| Stuck at | Symptom | Most likely cause | Fix |
|---|---|---|---|
| Certificate | `Issuing=True, Ready=False`, no CertificateRequest progressing | `ClusterIssuer` not `Ready` | `kubectl get clusterissuer letsencrypt-production` — check ACME account registration |
| CertificateRequest | "approved, but is not ready" | Order is stuck | walk down to Order |
| Order | `pending` | Challenge failing | walk down to Challenge |
| Challenge | "secrets `duckdns-api-token` is forbidden" | Webhook RBAC missing on the DuckDNS token Secret | re-apply `k8s/cluster-addons/cert-pipeline/00-webhook-secret-rbac.yaml` |
| Challenge | "no matches for kind Certificate" | cert-manager CRDs missing | re-apply the cert-pipeline; if persistent, `terraform apply` to reinstall the cert-manager Helm release |
| Challenge | SERVFAIL on `_acme-challenge.<fqdn>` | DuckDNS API rejected the TXT update; usually a wrong token | `kubectl get secret duckdns-api-token -n cert-manager -o jsonpath='{.data.token}' \| base64 -d` — verify it matches the live DuckDNS dashboard |
| Challenge | DNS propagation timeout | Cluster DNS resolver can't see public TXT records | rare on AKS; usually self-resolves on retry |

Common fast retries:

```bash
# Force cert-manager to retry the current Challenge without waiting for backoff
kubectl delete challenge -n cert-manager -l acme.cert-manager.io/order-name=<order-name>

# Or nuke the whole chain and let it rebuild
kubectl delete certificaterequest,order,challenge -n cert-manager \
  -l cert-manager.io/certificate-name=ticketing-tls
```

## Rate-limit awareness

Let's Encrypt production has rate limits that bite during a debug loop:

- **Certificates per registered domain:** 50 / week. DuckDNS is on the Public Suffix List, so each `<sub>.duckdns.org` counts as its own registered domain — this project has its own budget.
- **Duplicate certificates:** 5 / week for the same exact set of SANs. Most likely to bite if forcing renewal repeatedly.
- **Failed validations:** 5 / hour per account, per hostname. Usually only hit when debugging the webhook or the ClusterIssuer config.

If a rate limit is hit, the `Order` event will quote the exact limit. Switch the `Certificate.spec.issuerRef.name` to `letsencrypt-staging` in [`k8s/cluster-addons/cert-pipeline/05-certificate-ticketing-tls.yaml`](../k8s/cluster-addons/cert-pipeline/05-certificate-ticketing-tls.yaml) while iterating; staging has no rate limits but the issued cert is not browser-trusted. Switch back to production once the underlying issue is fixed.

## ACME account keys across teardown/rebuild

cert-manager registers an ACME account with Let's Encrypt the first time each `ClusterIssuer` reconciles, and stores the account private key in a K8s `Secret` named via `privateKeySecretRef`:

- `cert-manager/letsencrypt-staging-account-key`
- `cert-manager/letsencrypt-production-account-key`

Fresh clusters register fresh accounts unless those Secrets are pre-seeded. For the deploy-tear-down loop, account keys can be exported before teardown and re-applied on the next deploy:

```bash
# Export (before destroy)
kubectl get secret -n cert-manager letsencrypt-staging-account-key \
  -o yaml > letsencrypt-staging-account-key.yaml
kubectl get secret -n cert-manager letsencrypt-production-account-key \
  -o yaml > letsencrypt-production-account-key.yaml

# Strip cluster-specific metadata (resourceVersion, uid, creationTimestamp,
# managedFields, last-applied-configuration annotation) before re-apply.

# Re-apply (after cert-manager namespace exists, before ClusterIssuers reconcile)
kubectl apply -f letsencrypt-staging-account-key.yaml
kubectl apply -f letsencrypt-production-account-key.yaml
```

Both files are **gitignored** — they contain account private keys, never commit them. Automating this through ESO + Key Vault is a planned follow-up under Tier 1 #1 in `phase_3_plan.md`.

For the current cadence, forgetting to export them is low-stakes — Let's Encrypt's new-account rate limit (10 per IP / 3 hours) is well above the redeploy rate, and DuckDNS-on-PSL means each subdomain has its own per-domain budget.
