# Design

## Context

See `proposal.md` for motivation and `specs/single-sign-on/spec.md` for the required behaviour.

The cluster this deploys to, which the manifests must match:

- One GKE cluster. Protected apps may run in any namespace.
- TLS comes from cert-manager `Certificate` resources using the `letsencrypt-prod` ClusterIssuer.
- Secrets are created by hand with `kubectl`, not committed.
- Ingresses use `ingressClassName: nginx` with `nginx.ingress.kubernetes.io/*` annotations, so
  the controller is the community ingress-nginx.
- In-cluster callers use service names and never pass through the ingress, so they are
  unaffected by ingress authentication.

Constraints:

- ingress-nginx was retired in March 2026 and receives no fixes. The sign-on service must not be
  tied to it more than necessary.
- One user, one cluster, no high-availability requirement.

Assumptions made while planning, not explicitly confirmed by the owner:

- The auth host name is `auth.atorma.fi`.
- Sessions are not refreshed against Google during their 7 days.
- Sessions are stateless cookies, so revocation is all-or-nothing.
- Access is browser-only, with no header or token fallback.

## Goals / Non-Goals

**Goals:**

- No security-sensitive code of our own: login, 2FA and brute-force protection belong to Google.
- Nothing stateful to operate: no database or session store.
- Adding an app later is an ingress-only edit in that app's repository.
- Reversible: an app can go back to basic auth by reverting its ingress.

**Non-Goals:**

- Authenticating non-browser clients.
- Passing the user's identity to apps. Apps keep treating every request that reaches them as the
  owner's.
- Migrating off ingress-nginx.

## Decisions

### 1. oauth2-proxy with the Google provider

One oauth2-proxy Deployment handles both jobs: the OAuth login flow and the per-request session
check. Pinned to release v7.15.6 by image digest.

Alternatives considered:

- **Own cookie service:** full control, but we would own credential handling, rate limiting,
  cookie signing and redirect validation.
- **Authelia or similar:** adds its own user database and configuration for a single user.
- **Cloudflare Access / Google IAP:** no in-cluster service, but they require moving DNS behind
  Cloudflare or putting a Google Application Load Balancer in front of the ingress.
- **Tailscale / client certificates:** no login at all, but tie access to enrolled devices.

### 2. One auth host, called through the ingress's external-auth hook

```
 browser --> app host (ingress) --subrequest--> oauth2-proxy Service (in-cluster) --> 202 / 401
                 |  401
                 v
 browser --> https://auth.atorma.fi/oauth2/start?rd=<original URL> --> Google --> /oauth2/callback
                                                                                      |
                                                    Set-Cookie Domain=.atorma.fi, redirect to rd
```

- `auth.atorma.fi` gets its own Ingress and Certificate, with no auth annotations.
- Protected apps set two annotations:
    - `auth-url` points at the in-cluster Service (`/oauth2/auth`), so the check does not leave the
      cluster or depend on the public hostname.
    - `auth-signin` points at `https://auth.atorma.fi/oauth2/start` with `rd` set to the full
      original URL (`$scheme://$host$escaped_request_uri`). The full URL is needed because the
      login happens on a different host from the app.
- A single OAuth redirect URI, `https://auth.atorma.fi/oauth2/callback`, serves every app.
- oauth2-proxy runs with `--reverse-proxy`, a static `202` upstream, and
  `--skip-provider-button`, so an anonymous visit goes straight to Google.

The contract (subrequest returns 2xx or 401, then redirect to a sign-in URL) is also supported by
Traefik ForwardAuth and Envoy-based Gateway controllers, so only the two annotations need
rewriting when the ingress controller is replaced.

Alternative considered: mounting `/oauth2/*` on every app host. That needs one OAuth redirect URI
and one extra Ingress per app, which defeats "ingress-only edit".

### 3. Allowlist by emails file only

Access is restricted with `--authenticated-emails-file`, mounted from a Secret. `--email-domain`
is deliberately left unset.

The oauth2-proxy source (`validator.go`, v7.15.6) ORs the two checks, and `--email-domain=*`
overrides both. Setting the wildcard next to the file, as many examples do, would admit every
Google account. oauth2-proxy starts without `--email-domain` as long as the emails file is set.

The file is a Secret, not a ConfigMap, so the address is not committed. It is created from a
local gitignored file.

### 4. Stateless 7-day cookie session, no refresh

- `--session-store-type=cookie` (the default): the encrypted session lives in the cookie, so
  restarts do not log anyone out and there is no Redis to run.
- `--cookie-expire=168h` (7 days), as the owner chose to start with weekly sign-ins. This is
  also oauth2-proxy's default, but it is set explicitly so the manifest states it. Lengthening
  it later is a one-line change and a spec update.
- `--cookie-refresh` left disabled. Refreshing would need Google refresh tokens and adds a way
  for sessions to fail early; a personal single-user setup gains little from hourly rechecks.
- `--cookie-domain=.atorma.fi`, `--whitelist-domain=.atorma.fi`, `--cookie-samesite=lax`.
  `Secure` and `HttpOnly` are oauth2-proxy defaults and are left on.

Consequence: a session cannot be revoked individually. Revocation is rotating the cookie secret
and restarting the Deployment, which logs out every device. Removing an address from the
allowlist is not relied on to end existing sessions.

Alternative considered: Redis session store, for per-session revocation and small cookies. Not
worth a stateful service for one user.

### 5. Secrets created by hand, configuration in the manifest

- `oauth2-proxy-secrets`: OAuth client ID, client secret and cookie secret, injected as
  `OAUTH2_PROXY_*` environment variables.
- `oauth2-proxy-allowed-emails`: the emails file, mounted read-only.
- Non-secret settings are container arguments in the Deployment, so the manifest shows the whole
  security-relevant configuration in one place.

The runbook gives the `kubectl create secret` commands. `.gitignore` covers the local files they
read.

### 6. Repository layout

```
 k8s/                 kustomization.yaml, namespace.yaml, deployment.yaml, service.yaml, ingress.yaml,
                      certificate.yaml
 deploy.sh            kubectl apply -k k8s, then wait for rollout
 rotate-cookie-secret.sh   revoke all sessions (decision 9)
 README.md            first-time setup, app opt-in snippet, revocation, rollback
```

One replica, small resource requests, and readiness/liveness probes on oauth2-proxy's `/ping`.

### 7. Google OAuth client

A "Web application" OAuth client in the user's existing Google Cloud project, consent screen of
user type External, requesting only the basic sign-in scopes.

Per Google's consent-screen documentation, apps requesting only `openid`, `email` and `profile`
are exempt from the test-user list and from the 7-day authorization expiry even in Testing
status. Since no refresh token is used, that expiry would not affect sessions anyway.

### 8. The repository is public

The repository is published as open source, so everything tracked, including these planning
documents and the commit history, is treated as public.

- **Never tracked:** the OAuth client secret, the cookie secret, allowlisted email addresses, and
  the local files the secrets are created from. They exist only as cluster Secrets and gitignored
  local files.
- **Public by nature, so tracked as-is:** the domain and host names (already visible in DNS and
  certificate transparency logs), Kubernetes resource and Secret *names*, the OAuth redirect URI,
  and the oauth2-proxy configuration. The design does not rely on any of these being unknown.
- **OAuth client ID:** not a secret by Google's model, but kept in the Secret with the client
  secret so no account-specific identifier is committed.
- **Enforcement:** a secret scanner (gitleaks) runs as a pre-commit hook and over the full
  history before the first push. GitHub push protection is a second net, not the control.
- **Examples in the README use placeholders** for every secret value and email address.
- **Licence:** MIT, as in the owner's other public repositories.

Alternative considered: templating the domain out of the manifests with `envsubst`.
It would make the repository reusable by others, but adds a render step and hides nothing, since
the domain is public. The manifests keep the domain literal.

### 9. Secret rotation is manual, one command

`rotate-cookie-secret.sh` revokes every session. It generates a new random cookie secret, replaces
only that key in `oauth2-proxy-secrets` (leaving the OAuth client ID and secret in place),
restarts the Deployment and waits for the rollout. It never prints the secret or writes it to
disk.

Rotation is a response to an event (a lost device, a secret exposed by mistake), so it should be
quick and hard to get wrong, not scheduled.

The OAuth client secret is rotated by hand in the Google Cloud console and then updated in the
cluster Secret; the README describes the steps. It has no script because the first half cannot be
done from here.

### 10. Dedicated `auth` namespace

Everything the sign-on service owns lives in a namespace named `auth`: the Deployment, Service,
Ingress, Certificate and both Secrets.

- **Fixed and explicit:** the Kustomization sets `namespace: auth`, and the scripts pass
  `-n auth`. Nothing depends on the current kubectl context's namespace, because every protected
  ingress hard-codes the Service address `oauth2-proxy.auth.svc.cluster.local`.
- **Works for apps anywhere:** the ingress controller, not the app, makes the auth request, and
  the full Service name resolves from any namespace.
- **Isolation:** the secrets that guard every app are kept apart from the apps' own namespaces,
  so access to them can be granted separately.
- **First-time order:** the namespace must exist before the Secrets can be created, and the
  Secrets before the Deployment can start. The README has the owner apply `namespace.yaml`,
  create the Secrets, then run `deploy.sh`.

Alternative considered: the `default` namespace, alongside the apps. Simpler by one manifest, but
it mixes the sign-on secrets with every app's and makes removal piecemeal.

## Risks / Trade-offs

- [Publishing the setup tells a reader which controller and auth proxy guard the domain, and that
  the controller is retired] → Both are discoverable from the live hosts in a request or two;
  security rests on Google sign-in and the allowlist, not on obscurity.
- [A secret is committed by mistake and stays in history after a later fix] → Scanner hook before
  commit; if it happens anyway, rotate the secret first, then rewrite history.
- [The ingress controller is retired and unpatched] → Out of scope here; the design keeps the
  coupling to two annotations per app.
- [Sign-on service down means every protected app is unreachable] → Accepted for personal use;
  failing closed is required. Rollback per app is reverting its ingress to basic auth.
- [Large session cookie: Google tokens can push it past 4 KB, and nginx may reject the callback
  response with "upstream sent too big header"] → Set a larger `proxy-buffer-size` on the auth
  Ingress, and check during verification whether protected apps need the same.
- [An app's background requests after expiry get a redirect to Google instead of a 401, which
  `fetch` cannot follow] → Happens about once a week per device; a page reload signs in again.
  Unsaved form input at that moment is lost.
- [iOS home-screen web apps keep a cookie jar separate from Safari] → Expect one sign-in per
  installed app.
- [Lost or stolen device holds a valid session for up to 7 days] → Rotate the cookie secret.
- [A stolen cookie works on every protected host] → Inherent to domain-wide SSO; mitigated by
  `Secure`, `HttpOnly` and `SameSite=Lax`.
- [Any app on a `*.atorma.fi` host receives the session cookie] → Only host first-party apps
  under this domain.

## Migration Plan

1. Deploy the sign-on service and verify it on its own at `auth.atorma.fi`. No app is affected.
2. In a follow-up change in `training-ai`, swap the ingress annotations. Keep the
   `training-ai-basic-auth` secret until sign-on is verified on a phone.
3. Delete the basic-auth secret.

Rollback: revert the app's ingress to the basic-auth annotations. The sign-on service can stay
deployed or be removed with `kubectl delete -k k8s`, which deletes the `auth` namespace and with
it the hand-created Secrets.

## Open Questions

- Does Google require the consent screen to be published to "In production" for long-term use
  with only basic scopes? The documentation read says Testing status is enough; if sign-in starts
  failing or showing warnings, publish the app. No verification review is expected for these
  scopes, but that was not confirmed.
