terraform {
  required_version = ">= 0.13"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "resource_group" {
  default = "azuregoat_app"
}

variable "location" {
  type    = string
  default = "westus"
}

resource "random_id" "randomId" {
  keepers = {
    resource_group_name = var.resource_group
  }
  byte_length = 3
}

resource "azurerm_storage_account" "storage_account" {
  name                            = "appazgoat${random_id.randomId.dec}storage"
  resource_group_name             = var.resource_group
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = true
}

resource "azurerm_storage_container" "storage_container" {
  name                  = "appazgoat${random_id.randomId.dec}-storage-container"
  storage_account_name  = azurerm_storage_account.storage_account.name
  container_access_type = "blob"
}

locals {
  now        = timestamp()
  sasExpiry  = timeadd(local.now, "240h")
  date_now   = formatdate("YYYY-MM-DD", local.now)
  date_br    = formatdate("YYYY-MM-DD", local.sasExpiry)
  mime_types = {
    "txt" = "text/plain"
    "sh"  = "text/x-shellscript"
  }
}

data "azurerm_storage_account_blob_container_sas" "storage_account_blob_container_sas" {
  connection_string = azurerm_storage_account.storage_account.primary_connection_string
  container_name    = azurerm_storage_container.storage_container.name
  start             = local.date_now
  expiry            = local.date_br
  permissions {
    read   = true
    add    = true
    create = true
    write  = true
    delete = false
    list   = false
  }
}

resource "azurerm_service_plan" "app_service_plan" {
  name                = "appazgoat${random_id.randomId.dec}-app-service-plan"
  resource_group_name = var.resource_group
  location            = var.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

data "archive_file" "file_function_app" {
  type        = "zip"
  source_dir  = "modules/module-1/resources/azure_function/data"
  output_path = "modules/module-1/resources/azure_function/data/data-api.zip"
}

resource "azurerm_storage_blob" "storage_blob" {
  name                   = "modules/module-1/resources/azure_function/data/data-api.zip"
  storage_account_name   = azurerm_storage_account.storage_account.name
  storage_container_name = azurerm_storage_container.storage_container.name
  type                   = "Block"
  source                 = "modules/module-1/resources/azure_function/data/data-api.zip"
  depends_on             = [data.archive_file.file_function_app]
}

resource "azurerm_linux_function_app" "function_app" {
  name                       = "appazgoat${random_id.randomId.dec}-function"
  resource_group_name        = var.resource_group
  location                   = var.location
  service_plan_id            = azurerm_service_plan.app_service_plan.id
  storage_account_name       = azurerm_storage_account.storage_account.name
  storage_account_access_key = azurerm_storage_account.storage_account.primary_access_key

  app_settings = {
    "WEBSITE_RUN_FROM_PACKAGE" = "https://${azurerm_storage_account.storage_account.name}.blob.core.windows.net/${azurerm_storage_container.storage_container.name}/${azurerm_storage_blob.storage_blob.name}${data.azurerm_storage_account_blob_container_sas.storage_account_blob_container_sas.sas}",
    FUNCTIONS_WORKER_RUNTIME  = "python",
  }

  site_config {
    application_stack {
      python_version = "3.9"
    }
  }
}

resource "azurerm_network_security_group" "net_sg" {
  name                = "SecGroupNet${random_id.randomId.dec}"
  location            = var.location
  resource_group_name = var.resource_group

  security_rule {
    name                       = "SSH"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_virtual_network" "vNet" {
  name                = "vNet${random_id.randomId.dec}"
  address_space       = ["10.1.0.0/16"]
  location            = var.location
  resource_group_name = var.resource_group
}

resource "azurerm_subnet" "vNet_subnet" {
  name                 = "Subnet${random_id.randomId.dec}"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.vNet.name
  address_prefixes     = ["10.1.0.0/24"]
  depends_on           = [azurerm_virtual_network.vNet]
}

resource "azurerm_public_ip" "VM_PublicIP" {
  name                    = "developerVMPublicIP${random_id.randomId.dec}"
  resource_group_name     = var.resource_group
  location                = var.location
  allocation_method       = "Dynamic"
  idle_timeout_in_minutes = 4
  domain_name_label       = lower("developervm-${random_id.randomId.dec}")
  sku                     = "Basic"
}

data "azurerm_public_ip" "vm_ip" {
  name                = azurerm_public_ip.VM_PublicIP.name
  resource_group_name = var.resource_group
  depends_on          = [azurerm_linux_virtual_machine.dev-vm]
}

resource "azurerm_network_interface" "net_int" {
  name                = "developerVMNetInt"
  location            = var.location
  resource_group_name = var.resource_group

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.vNet_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.VM_PublicIP.id
  }
  depends_on = [azurerm_network_security_group.net_sg, azurerm_public_ip.VM_PublicIP, azurerm_subnet.vNet_subnet]
}

resource "azurerm_network_interface_security_group_association" "example" {
  network_interface_id      = azurerm_network_interface.net_int.id
  network_security_group_id = azurerm_network_security_group.net_sg.id
}

resource "azurerm_linux_virtual_machine" "dev-vm" {
  name                  = "developerVM${random_id.randomId.dec}"
  resource_group_name   = var.resource_group
  location              = var.location
  size                  = "Standard_B1s"
  admin_username        = "azureuser"
  admin_password        = "St0r95p@$sw0rd@1265463541"
  disable_password_authentication = false

  network_interface_ids = [azurerm_network_interface.net_int.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  depends_on = [azurerm_network_interface.net_int]
}

resource "azurerm_storage_blob" "config_update" {
  name                   = "modules/module-1/resources/storage_account/shared/files/.ssh/config.txt"
  storage_account_name   = azurerm_storage_account.storage_account.name
  storage_container_name = azurerm_storage_container.storage_container.name
  type                   = "Block"
  source                 = "modules/module-1/resources/storage_account/shared/files/.ssh/config.txt"
  content_type           = lookup(local.mime_types, "txt")
  depends_on             = [azurerm_linux_virtual_machine.dev-vm, data.azurerm_public_ip.vm_ip]
}

resource "null_resource" "file_replacement_vm_ip" {
  provisioner "local-exec" {
    command     = "sed -i 's/VM_IP_ADDR/${data.azurerm_public_ip.vm_ip.ip_address}/g' modules/module-1/resources/storage_account/shared/files/.ssh/config.txt"
    interpreter = ["/bin/bash", "-c"]
  }
  depends_on = [azurerm_linux_virtual_machine.dev-vm, data.azurerm_public_ip.vm_ip]
}

output "Target_URL" {
  value = "https://${azurerm_linux_function_app.function_app.name}.azurewebsites.net"
}

output "VM_Public_IP" {
  value = azurerm_public_ip.VM_PublicIP.ip_address
}
