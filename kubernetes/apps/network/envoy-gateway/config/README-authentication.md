# Envoy Gateway + Authentik OIDC Authentication

## Overview

This setup provides automatic authentication for services using dedicated authenticated gateways. No per-service configuration needed!

## Gateway Architecture

- **`envoy-internal`** (10.30.6.42) - No authentication
- **`envoy-internal-auth`** (10.30.6.43) - Requires Authentik login
- **`envoy-external`** (10.30.6.41) - Public, no authentication
- **`envoy-external-auth`** (10.30.6.44) - Requires Authentik login

## Setup Steps

### 1. Configure Authentik OIDC Provider

1. Log into Authentik: `https://sso.${SECRET_DOMAIN}`
2. Go to **Applications** → **Providers** → **Create**
3. Choose **OAuth2/OpenID Provider**
4. Configure:
   - **Name**: `envoy-gateway`
   - **Authorization flow**: `default-provider-authorization-implicit-consent`
   - **Client type**: `Confidential`
   - **Client ID**: `envoy-gateway` (or custom)
   - **Redirect URIs**:
     ```
     https://*.${SECRET_DOMAIN}/oauth2/callback
     ```
     (Use wildcard to cover all services automatically)
   - **Signing Key**: Select your certificate
5. Save and copy the **Client Secret**

### 2. Create Application

1. Go to **Applications** → **Create**
2. Configure:
   - **Name**: `Envoy Gateway`
   - **Slug**: `envoy-gateway`
   - **Provider**: Select the provider you just created
   - **Policy engine mode**: `any`
3. Save

### 3. Store Client Secret

Add the client secret to 1Password (or your secret manager):
- Item: `authentik`
- Field: `ENVOY_OIDC_CLIENT_SECRET` = `<paste-client-secret>`

Wait for Flux to sync the `authentik-oidc-secret` ExternalSecret.

### 4. Protect Services by Switching Gateways

To protect a service, simply change its gateway reference in the HTTPRoute or HelmRelease:

#### Example: Protect Grafana (internal)

In `kubernetes/apps/observability/grafana/app/helmrelease.yaml`:

```yaml
route:
  main:
    hostnames:
      - grafana.${SECRET_DOMAIN}
    parentRefs:
      - name: envoy-internal-auth  # Changed from envoy-internal
        namespace: network
```

#### Example: Protect Headlamp (internal)

In `kubernetes/apps/observability/headlamp/app/httproute.yaml`:

```yaml
spec:
  hostnames:
    - headlamp.${SECRET_DOMAIN}
  parentRefs:
    - name: envoy-internal-auth  # Changed from envoy-internal
      namespace: network
```

#### Example: Protect external service

For services using `envoy-external`, switch to `envoy-external-auth`:

```yaml
parentRefs:
  - name: envoy-external-auth  # Changed from envoy-external
    namespace: network
```

### 5. Testing

1. Change a test service to use `envoy-internal-auth` or `envoy-external-auth`
2. Wait for Flux to reconcile
3. Access the service URL
4. You should be redirected to Authentik login
5. After authentication, you'll be redirected back to the service

## How It Works

- **Transparent to applications**: Apps don't need OAuth support
- **Envoy Gateway intercepts** all requests to authenticated gateways
- **Checks authentication** before forwarding to the service
- **Redirects to Authentik** if not authenticated
- **No per-service configuration** needed beyond gateway selection

## Notes

- Use wildcard redirect URI `https://*.${SECRET_DOMAIN}/oauth2/callback` in Authentik
- Services on authenticated gateways automatically require login
- Applications without OAuth support (Headlamp, Filebrowser, etc.) work perfectly
- The same Authentik OIDC provider works for all services
- DNS and external-dns work the same way for all gateways
