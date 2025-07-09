# Configure the Azure Provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  features {}
}

# Variables
variable "resource_group_name" {
  description = "Name of the resource group for source storage and function app"
  type        = string
  default     = "rg-blob-sync-source"
}

variable "destination_resource_group_name" {
  description = "Name of the resource group for destination storage"
  type        = string
  default     = "rg-blob-sync-destination"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "East US"
}

variable "storage_account_1_name" {
  description = "Name of the source storage account"
  type        = string
  default     = "stgsource001"
}

variable "storage_account_2_name" {
  description = "Name of the destination storage account"
  type        = string
  default     = "stgdest001"
}

variable "container_name" {
  description = "Name of the container in both storage accounts"
  type        = string
  default     = "synccontainer"
}

variable "function_app_name" {
  description = "Name of the Function App"
  type        = string
  default     = "func-blob-sync"
}

variable "function_zip_path" {
  description = "Path to the function app zip file"
  type        = string
  default     = "./function-app.zip"
}

# Resource Group for Source Storage and Function App
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

# Resource Group for Destination Storage
resource "azurerm_resource_group" "destination" {
  name     = var.destination_resource_group_name
  location = var.location
}

# Storage Account 1 (Source)
resource "azurerm_storage_account" "source" {
  name                     = var.storage_account_1_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  
  blob_properties {
    versioning_enabled = true
    change_feed_enabled = true
  }
}

# Storage Account 2 (Destination) - In separate resource group
resource "azurerm_storage_account" "destination" {
  name                     = var.storage_account_2_name
  resource_group_name      = azurerm_resource_group.destination.name
  location                 = azurerm_resource_group.destination.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Container in Source Storage Account
resource "azurerm_storage_container" "source_container" {
  name                  = var.container_name
  storage_account_name  = azurerm_storage_account.source.name
  container_access_type = "private"
}

# Container in Destination Storage Account
resource "azurerm_storage_container" "destination_container" {
  name                  = var.container_name
  storage_account_name  = azurerm_storage_account.destination.name
  container_access_type = "private"
}

# App Service Plan for Function App
resource "azurerm_service_plan" "function_plan" {
  name                = "plan-${var.function_app_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

# Storage Account for Function App
resource "azurerm_storage_account" "function_storage" {
  name                     = "stgfunc${random_string.function_suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Random string for unique naming
resource "random_string" "function_suffix" {
  length  = 8
  special = false
  upper   = false
}

# Function App
resource "azurerm_linux_function_app" "blob_sync" {
  name                = var.function_app_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  site_config {
    application_stack {
      python_version = "3.9"
    }
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"       = "python"
    "AzureWebJobsFeatureFlags"      = "EnableWorkerIndexing"
    "SOURCE_STORAGE_CONNECTION"     = azurerm_storage_account.source.primary_connection_string
    "DESTINATION_STORAGE_CONNECTION" = azurerm_storage_account.destination.primary_connection_string
    "SOURCE_CONTAINER_NAME"         = var.container_name
    "DESTINATION_CONTAINER_NAME"    = var.container_name
  }

  zip_deploy_file = var.function_zip_path

  depends_on = [
    azurerm_storage_account.function_storage,
    azurerm_service_plan.function_plan
  ]
}

# Event Grid System Topic for Storage Account 1
resource "azurerm_eventgrid_system_topic" "source_storage_topic" {
  name                   = "eg-topic-${var.storage_account_1_name}"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  source_arm_resource_id = azurerm_storage_account.source.id
  topic_type             = "Microsoft.Storage.StorageAccounts"
}

# Event Grid Subscription for Function App
resource "azurerm_eventgrid_event_subscription" "blob_sync_subscription" {
  name  = "eg-sub-blob-sync"
  scope = azurerm_eventgrid_system_topic.source_storage_topic.id

  azure_function_endpoint {
    function_id = "${azurerm_linux_function_app.blob_sync.id}/functions/BlobSyncFunction"
  }

  included_event_types = [
    "Microsoft.Storage.BlobCreated",
    "Microsoft.Storage.BlobDeleted"
  ]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/${var.container_name}/blobs/"
  }

  advanced_filter {
    string_contains {
      key    = "subject"
      values = ["/containers/${var.container_name}/"]
    }
  }

  depends_on = [
    azurerm_linux_function_app.blob_sync
  ]
}

# Role Assignment for Function App to access source storage
resource "azurerm_role_assignment" "function_source_storage" {
  scope                = azurerm_storage_account.source.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_linux_function_app.blob_sync.identity[0].principal_id
}

# Role Assignment for Function App to access destination storage
resource "azurerm_role_assignment" "function_destination_storage" {
  scope                = azurerm_storage_account.destination.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_function_app.blob_sync.identity[0].principal_id
}

# Enable system assigned identity for Function App
resource "azurerm_linux_function_app" "blob_sync_identity" {
  name                = var.function_app_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  identity {
    type = "SystemAssigned"
  }
}

# Outputs
output "destination_resource_group_name" {
  description = "Name of the destination resource group"
  value       = azurerm_resource_group.destination.name
}

output "source_storage_account_name" {
  description = "Name of the source storage account"
  value       = azurerm_storage_account.source.name
}

output "destination_storage_account_name" {
  description = "Name of the destination storage account"
  value       = azurerm_storage_account.destination.name
}

output "function_app_name" {
  description = "Name of the Function App"
  value       = azurerm_linux_function_app.blob_sync.name
}

output "function_app_url" {
  description = "URL of the Function App"
  value       = azurerm_linux_function_app.blob_sync.default_hostname
}

output "source_container_url" {
  description = "URL of the source container"
  value       = "${azurerm_storage_account.source.primary_blob_endpoint}${var.container_name}"
}

output "destination_container_url" {
  description = "URL of the destination container"
  value       = "${azurerm_storage_account.destination.primary_blob_endpoint}${var.container_name}"
}
