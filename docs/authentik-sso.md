# Putting an app behind Authentik

Apps without their own login are protected with **forward auth**: Envoy Gateway
asks Authentik's embedded outpost about every request (a `SecurityPolicy` with
`extAuth` on the app's HTTPRoute) and only lets it through for a signed-in user
the app's Authentik policy allows. Everything is in git, in one place:

| Piece | File |
| --- | --- |
| Provider, application, who may use it, outpost membership | `kubernetes/apps/selfhosted/authentik/app/blueprints/forward-auth.yaml` (Authentik blueprint) |
| Which routes need a login, one policy per namespace | `kubernetes/apps/selfhosted/authentik/forward-auth/<namespace>.yaml` |
| Permission for those policies to call Authentik | `kubernetes/apps/selfhosted/authentik/app/referencegrant.yaml` |

Authentik's worker reloads when the blueprint ConfigMap changes and applies it.
Objects it manages are overwritten from git, so change them here, not in the
Authentik UI.

## Protecting an app

Example: `grafana` in `observability`, served at `grafana.${SECRET_DOMAIN}`.

1. **Blueprint**: in `forward-auth.yaml`, copy an app's three entries
   (provider, application, policy binding) and rename them: provider `name`,
   application `slug` and `name`, `external_host`, `meta_launch_url`, the `id`s.
   Providers reuse the shared settings with `<<: *forward-auth`.
   - With the policy binding, only `authentik Admins` get in. Drop it to let
     any signed-in user in (as for Overseerr).
2. **Outpost**: add `!KeyOf provider-grafana` to the embedded outpost's
   `providers` list at the bottom of the same file. The list is the complete
   set, so a provider left out stops working.
3. **Route**: add the HTTPRoute to `forward-auth/observability.yaml`'s
   `targetRefs`. For a new namespace, copy one of the files, set
   `metadata.namespace`, add it to `forward-auth/kustomization.yaml`, and add
   the namespace to `referencegrant.yaml`.

   Find the route name with `kubectl -n <ns> get httproute`.

Before protecting an app, check nothing calls it by its public hostname
(another app, a Home Assistant integration, a script): those calls would get
the login page. Point them at the in-cluster service or a LoadBalancer address
instead.

The outpost passes the user to the app in the `X-authentik-username`,
`-email`, `-name`, `-groups` and `-uid` request headers, for apps that can
use them.

## Apps with their own login

Apps that support OIDC (Grafana, Open WebUI, Paperless, ...) are better
connected directly with an OAuth2/OIDC provider: users get real accounts and
roles in the app instead of a gate in front of it.

## Checking it

- `kubectl get securitypolicy -A` shows each `authentik-forward-auth` policy
  `Accepted`.
- In Authentik, *Applications* lists the app and *Outposts* shows the embedded
  outpost with its provider.
- Blueprint errors: Authentik → *Customization → Blueprints* (status of
  `home-ops forward auth`), or the worker log.
- An app answering with Authentik's "Not Found" page means the outpost has no
  provider for that hostname: the blueprint was not applied, or the provider is
  missing from the outpost list.
