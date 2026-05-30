variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the ESO UAMI and federated credential"
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to the UAMI name (e.g. 'uami-ticketing-uksouth')"
  type        = string
}

variable "oidc_issuer_url" {
  description = "AKS cluster OIDC issuer URL — used as the federated credential issuer"
  type        = string
}

variable "key_vault_id" {
  description = "Resource ID of the Key Vault ESO reads from / writes to"
  type        = string
}

variable "key_vault_uri" {
  description = "Vault URI (e.g. https://kv-name.vault.azure.net) referenced by the ClusterSecretStore"
  type        = string
}

variable "chart_version" {
  description = "external-secrets Helm chart version. Releases: https://github.com/external-secrets/external-secrets/releases"
  type        = string
  default     = "0.10.5"
}

variable "tags" {
  description = "Tags applied to the UAMI"
  type        = map(string)
  default     = {}
}
