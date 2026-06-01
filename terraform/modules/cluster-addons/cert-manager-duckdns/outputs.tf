# ClusterIssuers and the cert pipeline manifests they're referenced from live
# in k8s/cluster-addons/cert-pipeline/, not in this module. No Terraform
# outputs are needed — the issuer names (`letsencrypt-staging`,
# `letsencrypt-production`) are written directly in the YAML manifests that
# consume them.
