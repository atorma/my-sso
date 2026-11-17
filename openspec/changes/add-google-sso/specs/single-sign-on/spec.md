# Spec Delta

## Purpose

Lets the owner sign in once per device with a Google account and then use every protected web app
under `atorma.fi` without being asked for credentials again, while keeping everyone else out.

## ADDED Requirements

### Requirement: Anonymous requests are sent to sign-in

A protected host SHALL NOT serve any content to a browser request that carries no valid session.
It SHALL redirect the browser to the sign-on service, which SHALL start a Google sign-in without
showing an intermediate page of its own.

#### Scenario: First visit on a new device

- **WHEN** a browser with no session requests a page on a protected host
- **THEN** the browser is redirected to Google sign-in and receives no content from the app

#### Scenario: Tampered session cookie

- **WHEN** a request to a protected host carries a session cookie that was not issued by the
  sign-on service or has been altered
- **THEN** the request is treated as anonymous

### Requirement: Sign-in returns to the requested page

After a successful sign-in, the sign-on service SHALL redirect the browser back to the URL it
originally requested, including path and query string.

#### Scenario: Deep link survives sign-in

- **WHEN** an anonymous browser requests `https://training-ai.atorma.fi/some/path?x=1` and then
  completes Google sign-in with an allowed account
- **THEN** the browser lands on `https://training-ai.atorma.fi/some/path?x=1` and the app serves it

### Requirement: Only allowlisted accounts may sign in

The sign-on service SHALL create a session only for a Google account whose email address is on
the configured allowlist. Any other account SHALL be denied and SHALL NOT receive a session.

#### Scenario: Allowed account

- **WHEN** a user completes Google sign-in with an allowlisted account
- **THEN** a session is created and the user reaches the app

#### Scenario: Other Google account

- **WHEN** a user completes Google sign-in with a valid Google account that is not on the allowlist
- **THEN** the sign-on service responds with an access-denied page, sets no session, and a
  subsequent request to a protected host is still treated as anonymous

### Requirement: One sign-in covers all protected hosts

A session created through any protected host SHALL be valid on every protected host under
`atorma.fi` in the same browser, with no further sign-in.

#### Scenario: Second app after signing in on the first

- **WHEN** a user has signed in while visiting one protected host and then opens a different
  protected host in the same browser
- **THEN** the second app is served immediately, with no redirect to sign-in

### Requirement: Sessions last 7 days

A session SHALL remain valid for 7 days from sign-in without any interaction from the user, and
SHALL be treated as anonymous after that. The session SHALL survive closing the browser and
restarts of the sign-on service.

#### Scenario: Return within the session lifetime

- **WHEN** a signed-in user returns to a protected host 5 days after signing in, having closed
  the browser in between
- **THEN** the app is served with no sign-in

#### Scenario: Sign-on service restarted

- **WHEN** the sign-on service is restarted or redeployed with unchanged configuration
- **THEN** existing sessions remain valid

#### Scenario: Session expired

- **WHEN** a user returns more than 7 days after signing in
- **THEN** the request is treated as anonymous and redirected to sign-in

### Requirement: Session cookie is protected

The session cookie SHALL be sent only over HTTPS, SHALL be inaccessible to page scripts, and
SHALL NOT be sent on cross-site subrequests.

#### Scenario: Cookie attributes

- **WHEN** the sign-on service sets the session cookie after sign-in
- **THEN** the cookie carries the `Secure` and `HttpOnly` attributes, `SameSite=Lax`, and a
  domain of `.atorma.fi`

### Requirement: Return URLs are limited to atorma.fi

The sign-on service SHALL redirect after sign-in only to HTTPS URLs on `atorma.fi` or its
subdomains. A return URL pointing anywhere else SHALL be ignored.

#### Scenario: Open-redirect attempt

- **WHEN** sign-in is started with a return URL on a domain other than `atorma.fi`
- **THEN** after sign-in the browser is not redirected to that domain

### Requirement: Sign-out ends the session

The sign-on service SHALL offer a sign-out URL that clears the session in the browser that
visits it.

#### Scenario: Sign out on one device

- **WHEN** a signed-in user visits the sign-out URL
- **THEN** the next request from that browser to any protected host is treated as anonymous

### Requirement: All sessions can be revoked at once

The operator SHALL be able to invalidate every existing session on every device with a single
documented operation, without changing any app.

#### Scenario: Lost device

- **WHEN** the operator performs the documented revocation
- **THEN** every previously signed-in browser is treated as anonymous on its next request

### Requirement: Fail closed when sign-on is unavailable

A protected host SHALL refuse requests when the sign-on service cannot be reached. It SHALL NOT
serve app content without a verified session.

#### Scenario: Sign-on service down

- **WHEN** the sign-on service is not running and a browser requests a protected host
- **THEN** the browser receives an error response and no app content

### Requirement: Secrets and identities stay out of the repository

The repository is public. Neither its tracked files nor its commit history SHALL contain the
OAuth client secret, the cookie signing secret, or any allowlisted email address. These SHALL be
supplied to the cluster at deploy time.

#### Scenario: Repository contents

- **WHEN** the tracked files and the full commit history are scanned for secrets and for the
  allowlisted addresses
- **THEN** none are found

#### Scenario: Documentation examples

- **WHEN** the documentation shows a command or file that takes a secret or an email address
- **THEN** it uses a placeholder, not a real value

#### Scenario: Secret staged by mistake

- **WHEN** a commit is attempted that contains a recognisable secret
- **THEN** the commit is blocked before it is created
