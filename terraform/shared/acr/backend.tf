terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "stterraformstatefloryda"
    container_name       = "tfstate-ticketing"
    key                  = "shared-acr.tfstate"
  }
}