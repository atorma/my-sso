#!/bin/sh
# Revoke every sign-on session on every device.
#
# Generates a new cookie secret, replaces only the "cookie-secret" key of the
# oauth2-proxy-secrets Secret (the OAuth client ID and secret are left as they are),
# then restarts oauth2-proxy and waits for it. Cookies signed with the old secret
# are rejected, so every browser has to sign in again.
#
# The secret is never printed, written to disk, or passed as a command argument:
# it travels through a pipe into "kubectl patch --patch-file=/dev/stdin".
set -eu

NAMESPACE=auth
SECRET=oauth2-proxy-secrets
DEPLOYMENT=oauth2-proxy

# Fail early, before generating anything, if the Secret is missing.
kubectl get secret "$SECRET" -n "$NAMESPACE" -o name >/dev/null

# 32 random bytes, URL-safe base64 (what oauth2-proxy expects), then base64 again
# for the Secret's data field. read and printf are shell builtins, so the value
# never appears in a process argument list.
openssl rand -base64 32 | tr -d '\n' | tr -- '+/' '-_' | base64 | tr -d '\n' |
  {
    IFS= read -r value || [ -n "$value" ]
    printf '{"data":{"cookie-secret":"%s"}}' "$value"
  } |
  kubectl patch secret "$SECRET" -n "$NAMESPACE" --type=merge --patch-file=/dev/stdin

kubectl rollout restart deployment/"$DEPLOYMENT" -n "$NAMESPACE"
kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=180s

echo "Cookie secret rotated. Every existing session is now invalid."
