---
applyTo: "kubernetes/apps/**/helmrelease.yaml"
---

# Instructions for HelmRelease files

## HelmReleases based on app-template

These rules apply only to a HelmRelease of the `app-template` chart. Such a
HelmRelease has an `ocirepository.yaml` next to it, with the `url`
`oci://ghcr.io/bjw-s-labs/helm/app-template`. Do not apply these rules to
another chart.

Apply them to the lines that you add or change. Do not sort a file that the
task does not change: a sort of the whole file makes a diff that is hard to
review.

### Key order

- An `enabled` field is the first field of its section, unless a rule below
  gives a different order.

- The keys of `spec`:
  - `chartRef`
  - `interval`
  - `dependsOn`
  - `install`
  - `upgrade`
  - `values`

- The keys of `spec.values`:
  - `defaultPodOptions`, if it is there
  - all other keys in alphabetical order (`controllers`, `persistence`,
    `route`, `service`, ...)

- The keys of each `spec.values.controllers.<name>`:
  - `type`
  - `annotations`
  - `labels`
  - the keys of the controller type, such as `cronjob` or `statefulset`
  - `pod`
  - all other keys in alphabetical order
  - `initContainers`
  - `containers`

- The keys of each container in `containers` and `initContainers`:
  - `image`
  - all other keys in alphabetical order

- The keys of `resources`:
  - `requests`
  - `limits`

- The keys of each `spec.values.service.<name>`:
  - `type`
  - `annotations`
  - `labels`
  - all other keys in alphabetical order

- The keys of each `spec.values.persistence.<name>`:
  - `type`
  - `annotations`
  - `labels`
  - all other keys in alphabetical order
  - `globalMounts`
  - `advancedMounts`

- In each other section: `annotations`, then `labels`, then all other keys in
  alphabetical order.

### What not to sort

- Do not sort the items of `controllers`, `containers`, `persistence`,
  `service` or `route`. For example, `persistence.config` can come before or
  after `persistence.data`. Sort only the keys inside each item.
- Do not sort the text inside a string, for example a YAML or an INI file in
  `configMaps.<name>.data`.
- Do not sort a list. The sequence of a list can have a meaning, for example
  `args` or `env`.
