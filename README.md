# my-sso

Single sign-on for personal web apps under `atorma.fi`.

[oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) with Google as the identity
provider runs at `auth.atorma.fi`. A protected app's ingress asks it whether each request
carries a valid session and sends anonymous browsers to Google sign-in. One sign-in sets a
7-day cookie for `.atorma.fi`, so it covers every protected host in that browser.

Only the Google accounts in an allowlist can sign in. The allowlist, the OAuth client and the
cookie secret live only in cluster Secrets, never in this repository.

```
 browser --> app host (ingress) --subrequest--> oauth2-proxy.auth (in-cluster) --> 202 / 401
                 |  401
                 v
 browser --> https://auth.atorma.fi/oauth2/start?rd=<original URL> --> Google --> /oauth2/callback
                                                                                      |
                                                   Set-Cookie Domain=.atorma.fi, redirect to rd
```

## Contents

| Path                      | Purpose                                                          |
| ------------------------- | ---------------------------------------------------------------- |
| `k8s/`                    | Kustomize root: namespace `auth`, Deployment, Service, Ingress, Certificate |
| `deploy.sh`               | Apply `k8s/` and wait for the rollout                            |
| `rotate-cookie-secret.sh` | Revoke every session on every device                             |
| `secrets/` (gitignored)   | Local input files for the two hand-created Secrets               |
| `openspec/`               | Design, requirements and tasks                                   |

Everything runs in the `auth` namespace. The scripts and the Kustomization name it explicitly,
so the current kubectl context's namespace does not matter. The kubectl *context* does: check
`kubectl config current-context` before running anything.

## First-time setup

### 1. Google OAuth client

In the [Google Cloud console](https://console.cloud.google.com/), in your project:

1. **Google Auth Platform → Branding / Audience:** configure the consent screen with user type
   **External**. oauth2-proxy requests only the non-sensitive `email` and `profile` scopes.
   Declaring them under **Data Access** (`.../auth/userinfo.email`, `.../auth/userinfo.profile`)
   is optional; do not add sensitive or restricted scopes. Publishing status *Testing* is enough
   for these scopes. If sign-in later starts failing or showing warnings, publish the app.
2. **Clients → Create client:** application type **Web application**, authorised redirect URI
   `https://auth.atorma.fi/oauth2/callback`. No JavaScript origins.
3. Keep the client ID and client secret for step 3.

### 2. DNS

Point `auth.atorma.fi` at the ingress controller's load balancer, the same address the other
`atorma.fi` hosts use. The ADDRESS column shows it:

```sh
kubectl get ingress -A
```

Check it resolves before deploying, or the certificate cannot be issued:

```sh
dig +short auth.atorma.fi
```

### 3. Namespace and Secrets

The namespace must exist before the Secrets, and the Secrets before the Deployment can start.

```sh
kubectl apply -f k8s/namespace.yaml
```

Create the local input files. `secrets/` is gitignored; keep them there and nowhere else.

```sh
mkdir -p secrets

# OAuth client from step 1. Edit the file to replace the placeholders.
cat > secrets/oauth2-proxy.env <<'END'
client-id=<GOOGLE_CLIENT_ID>
client-secret=<GOOGLE_CLIENT_SECRET>
END

# Cookie secret: 32 random bytes, URL-safe base64.
printf 'cookie-secret=%s\n' "$(openssl rand -base64 32 | tr -d '\n' | tr -- '+/' '-_')" \
  >> secrets/oauth2-proxy.env

# Allowlist: one Google account address per line. Edit to replace the placeholder.
echo '<ALLOWED_EMAIL>' > secrets/allowed-emails.txt
```

Create the two Secrets from them:

```sh
kubectl create secret generic oauth2-proxy-secrets -n auth \
  --from-env-file=secrets/oauth2-proxy.env

kubectl create secret generic oauth2-proxy-allowed-emails -n auth \
  --from-file=emails.txt=secrets/allowed-emails.txt

kubectl get secret -n auth
```

The local files are only needed to create the Secrets. You can delete them afterwards; the
client secret can be read again in the Google console.

### 4. Deploy

```sh
./deploy.sh
```

Then check:

```sh
kubectl get pods,certificate -n auth
curl -s -o /dev/null -w '%{http_code}\n' https://auth.atorma.fi/ping   # 200
```

Open <https://auth.atorma.fi/oauth2/start?rd=https://auth.atorma.fi/oauth2/userinfo> and sign
in. The page should show the signed-in address.

Later changes to `k8s/` are deployed the same way, with `./deploy.sh`.

## Protecting an app

In the app's own repository, replace the basic-auth annotations on its Ingress
(`nginx.ingress.kubernetes.io/auth-type`, `auth-secret` and `auth-realm`) with:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.auth.svc.cluster.local/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://auth.atorma.fi/oauth2/start?rd=$scheme://$host$escaped_request_uri"
```

- `auth-url` is the in-cluster Service, so the check never leaves the cluster. It works from any
  namespace.
- `auth-signin` sends anonymous browsers to sign in and back to the exact page they asked for.
- If sign-on is down, the ingress answers with an error. It never serves the app unauthenticated.
- Once sign-in works on the app, including on a phone, delete its basic-auth Secret.
- The app must be on an `atorma.fi` host. Sign-in only returns to `atorma.fi` URLs, and the
  session cookie is only sent there.
- Background `fetch` requests after the session expires get a redirect to Google, not a 401.
  Reloading the page signs in again.

## Signing out

Visit <https://auth.atorma.fi/oauth2/sign_out>. This ends the session in that browser only. To
end it everywhere, revoke all sessions.

## Revoking all sessions

For a lost device or a leaked cookie or secret:

```sh
./rotate-cookie-secret.sh
```

It replaces only the cookie secret in `oauth2-proxy-secrets` and restarts oauth2-proxy. Every
browser on every device then has to sign in again. The OAuth client is unchanged. The script
never prints the new secret or writes it to disk.

Sessions are stateless cookies, so there is no way to end one device's session alone. Removing an
address from the allowlist stops new sign-ins but does not end that account's existing sessions;
rotate the cookie secret as well.

## Changing the allowlist

Edit `secrets/allowed-emails.txt`, then replace the Secret and restart:

```sh
kubectl create secret generic oauth2-proxy-allowed-emails -n auth \
  --from-file=emails.txt=secrets/allowed-emails.txt --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/oauth2-proxy -n auth
kubectl rollout status deployment/oauth2-proxy -n auth
```

## Rotating the OAuth client secret

This is done by hand because the new secret comes from the Google console.

1. In the Google console, open the OAuth client and **add a secret**. Keep the old one enabled
   for now.
2. Put the new secret into the cluster without echoing it or leaving it in shell history:

   ```sh
   printf 'New client secret: '; stty -echo; IFS= read -r s; stty echo; echo
   printf '{"data":{"client-secret":"%s"}}' "$(printf '%s' "$s" | base64 | tr -d '\n')" |
     kubectl patch secret oauth2-proxy-secrets -n auth --type=merge --patch-file=/dev/stdin
   unset s
   kubectl rollout restart deployment/oauth2-proxy -n auth
   kubectl rollout status deployment/oauth2-proxy -n auth
   ```

3. Sign out and sign in again to check the new secret works.
4. Disable and delete the old secret in the Google console.

Existing sessions are not affected, because the cookie secret is unchanged.

## Rollback

- **One app:** revert its Ingress to the basic-auth annotations (and restore its basic-auth
  Secret if it was deleted). Sign-on can stay deployed.
- **A bad change to this repository:** revert the commit and run `./deploy.sh`.
- **Remove sign-on entirely:** first move every app back to basic auth, then

  ```sh
  kubectl delete -k k8s
  ```

  This deletes the `auth` namespace and with it the hand-created Secrets. Setting up again starts
  from step 3.

## Services without a browser

Sign-on is browser-only; there is no header or token alternative. Services that only machines or
scripts use stay in-cluster without a public Ingress and are reached with a port-forward:

```sh
kubectl port-forward -n <NAMESPACE> svc/<SERVICE> 8080:80
```

## Upgrading oauth2-proxy

The image is pinned by digest in `k8s/deployment.yaml`. To move to a new release, read its
changelog, then resolve the new digest and replace both the tag and digest:

```sh
docker buildx imagetools inspect quay.io/oauth2-proxy/oauth2-proxy:<VERSION>
```

## Keeping secrets out of the repository

This repository is public. A [gitleaks](https://github.com/gitleaks/gitleaks) pre-commit hook
blocks commits containing recognisable secrets. It runs with [prek](https://github.com/j178/prek)
(any pre-commit-compatible runner reads `.pre-commit-config.yaml`). Enable it once per clone:

```sh
brew install prek
prek install
```

Before pushing, the full history can be scanned with `gitleaks git`.

## License

MIT, see [LICENSE](LICENSE).
