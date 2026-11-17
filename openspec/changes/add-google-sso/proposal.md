# Proposal

## Why

Personal web apps under `atorma.fi` are each guarded by ingress basic auth, which mobile browsers
ask for again and again, and every app carries its own credential secret. A single login that
lasts long and covers every app removes that friction and the per-app secrets.

## What Changes

- Add a shared sign-on service at `auth.atorma.fi`: oauth2-proxy with Google as the identity
  provider, deployed to the existing GKE cluster from this repository.
- Restrict access to an allowlist of Google accounts (in practice one), supplied at deploy time
  and never committed.
- Issue a week-long session cookie scoped to `.atorma.fi`, so one login covers every protected
  host on that device.
- Document the ingress annotations an app uses to opt in, replacing its basic-auth annotations.
- Provide a deploy script and a runbook covering first-time setup, session revocation and
  rollback.

Out of scope:

- Editing any app's ingress.
- Non-browser access. Machine-only services stay in-cluster and are reached with
  `kubectl port-forward`; there is no header or token fallback.
- Replacing the retired ingress-nginx controller.

## Capabilities

### New Capabilities

- `single-sign-on`: browser sign-on shared by all protected `atorma.fi` hosts: who may sign in,
  how long a session lasts, how a protected host treats signed-in and anonymous requests, and
  how sessions are revoked.

### Modified Capabilities

None.

## Impact

- **New in this repository:** Kustomize manifests for the sign-on service (Deployment, Service,
  Ingress, Certificate), a deploy script, a session-revocation script, and a README
  runbook.
- **Cluster:** one small Deployment in a new `auth` namespace, two hand-created Secrets, and a
  certificate from the existing `letsencrypt-prod` ClusterIssuer.
- **External:** a Google OAuth client in the user's Google Cloud project, and a DNS record for
  `auth.atorma.fi`.
- **Dependencies:** the oauth2-proxy container image, and the ingress controller's external-auth
  support.
- **Other repositories:** none changed here. Each app later swaps three basic-auth annotations
  for two external-auth annotations and can then delete its basic-auth secret.
