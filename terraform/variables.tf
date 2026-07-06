variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "storage_account_name" {
  description = "Name of the storage account that stores our tfstate files"
  type        = string
}


variable "location" {
  description = "default resource location to use"
  type        = string
}