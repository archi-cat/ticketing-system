# Runbook — Deployment rollback

## Trigger

Use this runbook when a deployment to AKS has caused a degraded production state and you need to roll back to the previous version.

## Detection

Symptoms include:
- Error rate alert firing in Application Insights
- Health probe failures on api/worker/scheduler pods
- Customer-facing 5xx responses

## Procedure

### 1. Confirm the bad deployment

```powershell
kubectl rollout history deployment/api -n ticketing
```

### 2. Roll back to the previous revision

```powershell
kubectl rollout undo deployment/api -n ticketing
```

### 3. Watch the rollback complete

```powershell
kubectl rollout status deployment/api -n ticketing --timeout=120s
```

### 4. Verify recovery

- Check the error rate in Application Insights returns to baseline within 5 minutes
- Manually exercise the failing endpoint

### 5. Post-incident

- Open an issue describing what failed
- Add a regression test
- Add a note in the relevant ADR if the failure points to a design issue