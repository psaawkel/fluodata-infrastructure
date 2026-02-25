This directory contains a minimal, curated set of runtime manifests for the Scylla Operator used by ArgoCD.

Contents expected:
- CRDs (apiextensions/v1 YAMLs) — *only* the CRD files required by the operator (cleaned)
- controller Deployment, webhook Deployment, Service, ServiceAccount, ClusterRoles/RoleBindings
- optional cert-manager Issuer/Certificate if you manage webhook certs via cert-manager

Do not add source code, examples, vendor, or OLM CSVs here. Keep files small and focused for GitOps.
