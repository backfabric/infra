# Pod Security exemptions in exchange for pinned images

Amends ADR 0017. Some workloads the cluster must run cannot pass Pod Security `restricted`, or even `baseline`: agent runtimes whose node agents run as root with host paths, whose sandboxed workers need SYS_ADMIN and NET_ADMIN with seccomp and AppArmor Unconfined. Pod Security Admission can only exempt them by namespace, user or runtime class, and then admits anything in that namespace.

So the `k3s` subsystem lets a subsystem exempt a namespace only together with the exact images its pods may run: `backfabric.k3s.podSecurityExemptions.<namespace>.images`, each a reference pinned by digest (`…@sha256:<64 hex>`, enforced by the option's type). The namespaces join kube-system in the PodSecurity admission configuration's exemptions, and the ValidatingAdmissionPolicy `backfabric-exempt-namespace-images` (a k3s manifest, like the policy against NodePort Services) admits a pod in those namespaces only if the image of every container, init container and ephemeral container is in the namespace's list, on every create and update of a pod and of its ephemeral containers. Controllers' pod templates are checked when they create the pods. kube-system is not matched: its images come with k3s. The binding rejects and audits (`backfabric.k3s.denyUnlistedImages`, default true); turned off, it warns and audits, to try a new list without blocking anything. Without exemptions the policy is not deployed, and its manifest is listed in `backfabric.k3s.removedManifests`, so it is removed when the last exemption goes.

## Considered Options

- Pod Security exemptions by user (`usernames`): pods created by controllers are admitted under the controller's identity (the DaemonSet, ReplicaSet or StatefulSet controller), shared with every workload in the cluster.
- Kyverno or Gatekeeper: richer policies (security contexts, signatures), but an admission webhook with its own deployment, privileges and failure modes; a ValidatingAdmissionPolicy runs in the API server.
- Signature verification (e.g. sigstore policy-controller): needs signed images; the first user's images (Agent Substrate v1.0.0) are not signed.
- Matching repository prefixes instead of exact references: a pushed tag or any image of the repository would pass.

## Consequences

- The policy pins images, not security contexts: in an exempt namespace a listed image may run with any privileges, so whoever can create pods or controllers there can run it as root with host paths. Lists should be as short as possible; images with a shell widen what that allows.
- A subsystem that exempts a namespace must pin every image its pods can run, and change the pins with each upgrade; an unlisted image is rejected, so a forgotten one fails at deployment, visibly (the client's error, the audit log).
- Every host gets `backfabric-exempt-namespace-images` in `removedManifests` while it has no exemptions: one more k3s `--disable` entry, and one k3s restart when it appears or goes.
