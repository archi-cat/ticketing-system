output "staging_issuer_name" {
  description = "Name of the staging ClusterIssuer — reference this from a Certificate resource while iterating to avoid Let's Encrypt rate limits"
  value       = "letsencrypt-staging"
}

output "production_issuer_name" {
  description = "Name of the production ClusterIssuer — switch a Certificate to this once staging issuance is verified"
  value       = "letsencrypt-production"
}
