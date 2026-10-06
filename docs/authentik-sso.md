# Putting an app behind Authentik

Apps without their own login are protected with **forward auth**: Envoy Gateway
asks Authentik's embedded outpost about every request (a `SecurityPolicy` with
`extAuth` on the app's HTTPRoute) and only lets it through for a signed-in user
the app's Authentik policy allows. Everything is in git:

| Piece | File |
| --- | --- |
| Provider, application, who may use it, outpost membership | `kubernetes/apps/selfhosted/authentik/app/blueprints/forward-auth.yaml` (Authentik blueprint) |
| Envoy policy on the app's route | `kubernetes/components/authentik-forward-auth` (component) |
| Permission for policies in other namespaces to call Authentik | `kubernetes/apps/selfhosted/authentik/app/referencegrant.yaml` |

Authentik applies the blueprint on start and whenever the file changes. Objects
it manages are overwritten from git, so change them here, not in the Authentik UI.

## Protecting an app

Example: `grafana` in `observability`, served at `grafana.${SECRET_DOMAIN}`.

1. **Blueprint**: in `forward-auth.yaml`, copy the FileBrowser block and rename
   it (provider `name`, application `slug`, `external_host`, `id`s). Keep or
   drop the policy binding: with a binding, only that group gets in; without
   one, any signed-in user does.
2. **Outpost**: add `!KeyOf provider-grafana` to the embedded outpost's
   `providers` list at the bottom of the same file. The list is the complete
   set, so a provider left out stops working.
3. **Namespace**: if the app is not in `selfhosted`, make sure its namespace is
   listed in `referencegrant.yaml`.
4. **Route**: add the component to the app's `ks.yaml`:

   ```yaml
   spec:
     components:
       - ../../../../components/authentik-forward-auth
     postBuild:
       substitute:
         APP: grafana
         # AUTH_ROUTE: grafana-app   # only if the HTTPRoute is not named after APP
   ```

   Check the route name with `kubectl -n <ns> get httproute`.

Commit and let Flux apply it. Opening the app should now redirect to
`sso.${SECRET_DOMAIN}`.

The outpost passes the user to the app in the `X-authentik-username`,
`-email`, `-name`, `-groups` and `-uid` request headers, for apps that can
use them.

## Apps with their own login

Apps that support OIDC (Grafana, Open WebUI, Paperless, ...) are better
connected directly with an OAuth2/OIDC provider: users get real accounts and
roles in the app instead of a gate in front of it. Those providers can live in
the same kind of blueprint.

## Checking it

- `kubectl -n <ns> get securitypolicy` shows the policy `Accepted`.
- In Authentik, *Applications* lists the app and *Outposts* shows the embedded
  outpost with its provider.
- Blueprint errors: Authentik → *Customization → Blueprints* (status of
  `home-ops forward auth`), or the worker log.
