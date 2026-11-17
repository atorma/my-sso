# Tasks

Tasks marked **(owner)** need the repository owner: they use the Google Cloud console, DNS, or a
second Google account.

## 1. Manifests

- [ ] 1.1 Resolve the image digest for oauth2-proxy v7.15.6 from `quay.io/oauth2-proxy/oauth2-proxy` and record it; verify the digest pulls with `docker pull` or `crane digest`
- [ ] 1.2 Write `k8s/deployment.yaml` with the pinned image and the arguments from design decisions 2-4 (Google provider, emails file, no `--email-domain`, cookie and whitelist domain, 7-day expiry, static upstream, reverse-proxy, skip provider button), secrets from `oauth2-proxy-secrets` and the mounted `oauth2-proxy-allowed-emails`, plus probes and resource requests; verify every flag against `oauth2-proxy --help` for the pinned version
- [ ] 1.3 Write `k8s/namespace.yaml` (`auth`), `k8s/service.yaml`, `k8s/certificate.yaml` (`auth.atorma.fi`, `letsencrypt-prod`) and `k8s/ingress.yaml` (no auth annotations, larger `proxy-buffer-size`), and `k8s/kustomization.yaml` with `namespace: auth`; verify `kubectl kustomize k8s` renders without errors and every namespaced resource in the output is in `auth`
- [ ] 1.4 Extend `.gitignore` for the local secret input files, and verify `git check-ignore` matches each file name the README tells the owner to create
- [ ] 1.5 Add a gitleaks pre-commit hook (`.pre-commit-config.yaml`) and an MIT `LICENSE`; verify that committing a file containing a fake private key is blocked
- [ ] 1.6 Before the first push, run `gitleaks git` over the whole history and search tracked files for email addresses; verify both come back empty, and that commits carry a GitHub noreply author address

## 2. Deploy script and runbook

- [ ] 2.1 Write `deploy.sh` that applies the Kustomize root and waits for the rollout in the `auth` namespace, independent of the current context's namespace; verify `sh -n deploy.sh` passes and `kubectl apply -k k8s --dry-run=client` succeeds
- [ ] 2.2 Write `rotate-cookie-secret.sh` per design decision 9; verify `sh -n` passes and, by reading it, that no command echoes the secret or writes it to a file
- [ ] 2.3 Write `README.md` covering: Google OAuth client setup, DNS record, the first-time order (apply `namespace.yaml`, then the two `kubectl create secret -n auth` commands, then deploy), the annotation snippet for apps, sign-out URL, revoking all sessions with `rotate-cookie-secret.sh`, rotating the OAuth client secret by hand, rollback, and `kubectl port-forward` for machine-only services; use placeholders for every secret value and email address; verify each command against the manifests' resource names

## 3. First deployment

- [ ] 3.1 **(owner)** Create the Google OAuth client (Web application, redirect URI `https://auth.atorma.fi/oauth2/callback`, consent screen External); verify the client ID and secret are available
- [ ] 3.2 **(owner)** Add the DNS record for `auth.atorma.fi` pointing at the ingress load balancer; verify with `dig auth.atorma.fi`
- [ ] 3.3 **(owner)** Create the `oauth2-proxy-secrets` and `oauth2-proxy-allowed-emails` secrets in the `auth` namespace following the README; verify with `kubectl get secret -n auth`
- [ ] 3.4 Run `deploy.sh`; verify the pod is Ready, the certificate is issued, and `curl -s -o /dev/null -w '%{http_code}' https://auth.atorma.fi/ping` returns 200

## 4. Verification on the auth host

- [ ] 4.1 **(owner)** Open `https://auth.atorma.fi/oauth2/start?rd=https://auth.atorma.fi/oauth2/userinfo` and sign in with the allowlisted account; verify the browser returns to the userinfo page and the cookie has domain `.atorma.fi`, `Secure`, `HttpOnly`, `SameSite=Lax` and an expiry about 7 days ahead
- [ ] 4.2 **(owner)** In a private window, sign in with a Google account that is not allowlisted; verify an access-denied page and that `/oauth2/userinfo` then returns 401
- [ ] 4.3 Request `https://auth.atorma.fi/oauth2/start?rd=https://example.com/`; after sign-in, verify the browser is not sent to `example.com`
- [ ] 4.4 Restart the Deployment with `kubectl rollout restart -n auth`; verify the existing session still reaches `/oauth2/userinfo`
- [ ] 4.5 Visit `https://auth.atorma.fi/oauth2/sign_out`; verify `/oauth2/userinfo` then returns 401
- [ ] 4.6 Run `rotate-cookie-secret.sh`; verify its output does not contain the secret, that the Secret's client ID and client secret keys are unchanged, and that a previously signed-in browser gets 401 from `/oauth2/userinfo`, then sign in again
- [ ] 4.7 **(owner)** At least a day after signing in again, open `https://auth.atorma.fi/oauth2/userinfo` in the same browser; verify it answers without a sign-in, showing the session outlives Google's short-lived access token
- [ ] 4.8 Check the ingress controller logs for "too big header" during the sign-in flows above; if present, raise `proxy-buffer-size` and note in the README whether app ingresses need it too

## Workflow follow-up

- The tasks above verify the sign-on service on its own host only. These spec scenarios need a protected app and are verified by the `training-ai` change below, which is also the first real test of the README's annotation snippet: first visit on a new device, tampered session cookie, deep link survives sign-in, second app after signing in on the first (needs a second protected host, or the auth host as the first), and sign-on service down.
- In the `training-ai` repository, propose a change that replaces the three basic-auth annotations on its ingress with the documented `auth-url` and `auth-signin` annotations, verifies those scenarios from a phone, and then deletes `training-ai-basic-auth`.
- Archive this change only after that verification passes, and correct the README snippet here if it needed changes.
