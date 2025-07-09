# Configure the Azure Provider

terraform {
required_providers {
azurerm = {
source  = “hashicorp/azurerm”
version = “~>3.0”
}
}
}

# Configure the Microsoft Azure Provider

provider “azurerm” {
features {}
subscription_id = “POC-EDPGenAI-2”
}

# Variables

variable “location” {
description = “Azure region for all resources”
type        = string
default     = “UK South”
}

variable “function_zip_path” {
description = “Path to the function app zip file”
type        = string
default     = “./function-app.zip”
}

# Resource Group 1 - syncterraform1

resource “azurerm_resource_group” “syncterraform1” {
name     = “syncterraform1”
location = var.location
}

# Resource Group 2 - syncterraform2

resource “azurerm_resource_group” “syncterraform2” {
name     = “syncterraform2”
location = var.location
}

# Storage Account 1 - terraformstore1 (in syncterraform1)

resource “azurerm_storage_account” “terraformstore1” {
name                          = “terraformstore1”
resource_group_name           = azurerm_resource_group.syncterraform1.name
location                      = azurerm_resource_group.syncterraform1.location
account_tier                  = “Standard”
account_replication_type      = “GRS”
account_kind                  = “StorageV2”
is_hns_enabled               = true
allow_nested_items_to_be_public = true
cross_tenant_replication_enabled = true
public_network_access_enabled = true

blob_properties {
delete_retention_policy {
days = 0
}
container_delete_retention_policy {
days = 0
}
versioning_enabled = false
change_feed_enabled = false
}

network_rules {
default_action = “Allow”
}
}

# Storage Account 2 - terraformstore2 (in syncterraform2)

resource “azurerm_storage_account” “terraformstore2” {
name                          = “terraformstore2”
resource_group_name           = azurerm_resource_group.syncterraform2.name
location                      = azurerm_resource_group.syncterraform2.location
account_tier                  = “Standard”
account_replication_type      = “GRS”
account_kind                  = “StorageV2”
is_hns_enabled               = true
allow_nested_items_to_be_public = true
cross_tenant_replication_enabled = true
public_network_access_enabled = true

blob_properties {
delete_retention_policy {
days = 0
}
container_delete_retention_policy {
days = 0
}
versioning_enabled = false
change_feed_enabled = false
}

network_rules {
default_action = “Allow”
}
}

# Container 1 - container1 (in terraformstore1)

resource “azurerm_storage_container” “container1” {
name                  = “container1”
storage_account_name  = azurerm_storage_account.terraformstore1.name
container_access_type = “container”
}

# Container 2 - container2 (in terraformstore2)

resource “azurerm_storage_container” “container2” {
name                  = “container2”
storage_account_name  = azurerm_storage_account.terraformstore2.name
container_access_type = “container”
}

# App Service Plan for Function App (Flex Consumption)

resource “azurerm_service_plan” “function_plan” {
name                = “plan-sync-function”
resource_group_name = azurerm_resource_group.syncterraform1.name
location            = azurerm_resource_group.syncterraform1.location
os_type             = “Linux”
sku_name            = “FC1”
}

# Function App

resource “azurerm_linux_function_app” “sync_function” {
name                = “sync-function-app”
resource_group_name = azurerm_resource_group.syncterraform1.name
location            = azurerm_resource_group.syncterraform1.location
service_plan_id     = azurerm_service_plan.function_plan.id
storage_account_name       = azurerm_storage_account.terraformstore1.name
storage_account_access_key = azurerm_storage_account.terraformstore1.primary_access_key

site_config {
application_stack {
python_version = “3.11”
}
}

app_settings = {
“FUNCTIONS_WORKER_RUNTIME”     = “python”
“AzureWebJobsFeatureFlags”    = “EnableWorkerIndexing”
“DEST_CONNECTION_STRING”      = azurerm_storage_account.terraformstore2.primary_connection_string
“DEST_CONTAINER_NAME”         = “container2”
“FUNCTIONS_EXTENSION_VERSION” = “~4”
}

zip_deploy_file = var.function_zip_path

depends_on = [
azurerm_storage_account.terraformstore1,
azurerm_service_plan.function_plan
]
}

# Event Grid System Topic for terraformstore1

resource “azurerm_eventgrid_system_topic” “storage_topic” {
name                   = “eg-topic-terraformstore1”
resource_group_name    = azurerm_resource_group.syncterraform1.name
location               = azurerm_resource_group.syncterraform1.location
source_arm_resource_id = azurerm_storage_account.terraformstore1.id
topic_type             = “Microsoft.Storage.StorageAccounts”
}

# Event Grid Subscription - eventtrigger

resource “azurerm_eventgrid_event_subscription” “eventtrigger” {
name  = “eventtrigger”
scope = azurerm_eventgrid_system_topic.storage_topic.id

azure_function_endpoint {
function_id = “${azurerm_linux_function_app.sync_function.id}/functions/BlobSyncFunction”
}

included_event_types = [
“Microsoft.Storage.BlobCreated”,
“Microsoft.Storage.BlobDeleted”
]

subject_filter {
subject_begins_with = “/blobServices/default/containers/container1”
}

depends_on = [
azurerm_linux_function_app.sync_function
]
}

# Outputs

output “resource_group_1_name” {
description = “Name of the first resource group”
value       = azurerm_resource_group.syncterraform1.name
}

output “resource_group_2_name” {
description = “Name of the second resource group”
value       = azurerm_resource_group.syncterraform2.name
}

output “storage_account_1_name” {
description = “Name of the first storage account”
value       = azurerm_storage_account.terraformstore1.name
}

output “storage_account_2_name” {
description = “Name of the second storage account”
value       = azurerm_storage_account.terraformstore2.name
}

output “function_app_name” {
description = “Name of the Function App”
value       = azurerm_linux_function_app.sync_function.name
}

output “function_app_url” {
description = “URL of the Function App”
value       = azurerm_linux_function_app.sync_function.default_hostname
}

output “container1_url” {
description = “URL of container1”
value       = “${azurerm_storage_account.terraformstore1.primary_blob_endpoint}container1”
}

output “container2_url” {
description = “URL of container2”
value       = “${azurerm_storage_account.terraformstore2.primary_blob_endpoint}container2”
}
