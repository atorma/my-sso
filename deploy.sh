#!/bin/sh
# Apply the sign-on service and wait until it is running.
# Everything is in the "auth" namespace regardless of the current kubectl context's namespace.
# First time: create the namespace and the two Secrets first (see README).
set -eu

cd "$(dirname "$0")"

kubectl apply -k k8s
kubectl rollout status deployment/oauth2-proxy -n auth --timeout=180s
