
##########################################################
# Azure Provider
##########################################################
provider "azurerm" {
  features {
  resource_group {
  prevent_deletion_if_contains_resources = false
  }
  }
}



##########################################################
# Network infrastructure 
##########################################################
# resource group
resource "azurerm_resource_group" "purple_lab_rg" {
  name     = "${var.resource_prefix}-Lab-RG"                                   
  location = var.node_location_dc
  tags = var.tags
}

# virtual network within the resource group
resource "azurerm_virtual_network" "lab_vnet" {
  name                = "${var.resource_prefix}-lab-vnet"                      
  resource_group_name = azurerm_resource_group.purple_lab_rg.name
  location            = var.node_location_dc
  address_space       = var.node_address_space_dc
  dns_servers         = [cidrhost(var.node_address_prefix_dc, 10)]
  tags = var.tags
}

# subnet within the virtual network
resource "azurerm_subnet" "dc_subnet" {
  name                 = "${var.resource_prefix}-lab-subnet"                   
  resource_group_name  = azurerm_resource_group.purple_lab_rg.name
  virtual_network_name = azurerm_virtual_network.lab_vnet.name
  address_prefixes       = [var.node_address_prefix_dc]

}

# public ip - Shared resource between all vms
resource "azurerm_public_ip" "dc_public_ip" {
  name = "${var.resource_prefix}-DC-Public-IP"
  location            = azurerm_resource_group.purple_lab_rg.location                  
  resource_group_name = azurerm_resource_group.purple_lab_rg.name
  allocation_method   = "Dynamic"
  tags = var.tags
}

# network interface - dc
resource "azurerm_network_interface" "dc_nic" {
  name = "${var.resource_prefix}-DC-NIC"
  location            = azurerm_resource_group.purple_lab_rg.location                 
  resource_group_name = azurerm_resource_group.purple_lab_rg.name
  tags = var.tags

  ip_configuration {
    name      = "internal"
    subnet_id = azurerm_subnet.dc_subnet.id
    # private_ip_address_allocation = "Dynamic"
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(var.node_address_prefix_dc, 10)
    public_ip_address_id          = azurerm_public_ip.dc_public_ip.id
  }
}

# NSG DC
resource "azurerm_network_security_group" "dc_nsg" {                           
  name                = "${var.resource_prefix}-NSG"
  location            = azurerm_resource_group.purple_lab_rg.location
  resource_group_name = azurerm_resource_group.purple_lab_rg.name
  security_rule {
    name                       = "Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  tags = var.tags
}

# Subnet and NSG association DC
resource "azurerm_subnet_network_security_group_association" "dc_subnet_nsg_association" {   
  subnet_id                 = azurerm_subnet.dc_subnet.id                
  network_security_group_id = azurerm_network_security_group.dc_nsg.id

}



##########################################################
# Create Windows Server 2019
##########################################################
resource "azurerm_windows_virtual_machine" "Domain_Controller" {
  name                  = var.dc_name
  location              = azurerm_resource_group.purple_lab_rg.location
  resource_group_name   = azurerm_resource_group.purple_lab_rg.name
  network_interface_ids = [azurerm_network_interface.dc_nic.id]
  size                  = var.vmsize_dc
  admin_username        = var.domadminuser
  admin_password        = var.domadminpassword

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-Datacenter"
    version   = "latest"
  }

  tags = var.tags
}



##########################################################
## Define VM extensions to install ADDS and join member
##########################################################
# Promote VM to be a Domain Controller
# based on https://github.com/ghostinthewires/terraform-azurerm-promote-dc
locals { 
  import_command       = "Import-Module ADDSDeployment"
  password_command     = "$password = ConvertTo-SecureString ${var.safemode_password} -AsPlainText -Force"
  install_ad_command   = "Add-WindowsFeature -name ad-domain-services -IncludeManagementTools"
  configure_ad_command = "Install-ADDSForest -CreateDnsDelegation:$false -DomainMode Win2012R2 -DomainName ${var.active_directory_domain} -DomainNetbiosName ${var.active_directory_netbios_name} -ForestMode Win2012R2 -InstallDns:$true -SafeModeAdministratorPassword $password -Force:$true"
  shutdown_command     = "shutdown -r -t 10"
  powershell_command   = "${local.disable_fw}; ${local.import_command}; ${local.password_command}; ${local.install_ad_command}; ${local.configure_ad_command}; ${local.shutdown_command}; ${local.exit_code_hack}"
  
  exit_code_hack       = "exit 0"

  disable_fw          = "Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False"
  powershell_command_disable_fw   = "${local.disable_fw}; ${local.exit_code_hack}"
}

resource "azurerm_virtual_machine_extension" "create-active-directory-forest" {
  name                 = "create-active-directory-forest"
  virtual_machine_id   = azurerm_windows_virtual_machine.Domain_Controller.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  settings = <<SETTINGS
    {
        "commandToExecute": "powershell.exe -Command \"${local.powershell_command}\""
    }
SETTINGS
}






##########################################################
# Sleep - we need this to give the DC enough time to provision before joining VMs
##########################################################
 resource "time_sleep" "wait_300_seconds" {
  create_duration = "300s"
 depends_on = [azurerm_virtual_machine_extension.create-active-directory-forest]
}





##########################################################
# Workstation section
##########################################################

# public ips - workstation
resource "azurerm_public_ip" "workstation_public_ip" {
  count = var.node_count
  name                = "${var.resource_prefix}-${format("%02d", count.index)}-PublicIP"
  location            = azurerm_resource_group.purple_lab_rg.location
  resource_group_name = azurerm_resource_group.purple_lab_rg.name
  allocation_method   = "Dynamic"  # You can use "Static" if needed

  tags = var.tags
}

# network interfaces - workstation
resource "azurerm_network_interface" "workstation_nic" {
  count                 = var.node_count
  name                  = "${var.resource_prefix}-${format("%02d", count.index)}-NIC"               # This works when creating only 1 vm "workstation_nic"                                                   
  location              = azurerm_resource_group.purple_lab_rg.location
  resource_group_name   = azurerm_resource_group.purple_lab_rg.name
  tags = var.tags

  ip_configuration {
    name      = "internal"
    subnet_id = azurerm_subnet.dc_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address = cidrhost(var.node_address_prefix_dc, 100+count.index)
    public_ip_address_id = element(azurerm_public_ip.workstation_public_ip.*.id, count.index)
  }
}


##########################################################
# Create Windows 11 workstations
##########################################################
resource "azurerm_windows_virtual_machine" "workstation_vm" {
  count = var.node_count
  name  = "workstation-${format("%02d", count.index)}"
  location              = var.node_location_workstation # azurerm_resource_group.purple_lab_rg.location
  resource_group_name   = azurerm_resource_group.purple_lab_rg.name
  network_interface_ids =  [azurerm_network_interface.workstation_nic[count.index].id]          #   name  = "workstation-${format("%02d", count.index)}"                
  size                  = var.vmsize_workstation
  admin_username        = var.adminuser
  admin_password        = var.adminpassword

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-21h2-avd"
    version   = "latest"
  }

  depends_on = [time_sleep.wait_300_seconds]
  tags = var.tags
}











# Join VM to Active Directory Domain
# based on https://github.com/ghostinthewires/terraform-azurerm-ad-join
 resource "azurerm_virtual_machine_extension" "join-domain" {
  count = var.node_count
  virtual_machine_id   = azurerm_windows_virtual_machine.workstation_vm[count.index].id
  name                 = "join-domain"
  publisher            = "Microsoft.Compute"
  type                 = "JsonADDomainExtension"
  type_handler_version = "1.3"
  

  # NOTE: the `OUPath` field is intentionally blank, to put it in the Computers OU
  settings = <<SETTINGS
     {
        "Name": "${var.active_directory_domain}",
        "OUPath": "",
        "User": "${var.active_directory_domain}\\${var.domadminuser}",
        "Restart": "true",
        "Options": "3"
    }
SETTINGS

  protected_settings = <<SETTINGS
    {
        "Password": "${var.domadminpassword}"
    }
SETTINGS
}

resource "azurerm_virtual_machine_extension" "disable_fw_member" {
  depends_on = [azurerm_virtual_machine_extension.join-domain]
  count = var.node_count
  virtual_machine_id   = azurerm_windows_virtual_machine.workstation_vm[count.index].id
  name                 = "disable_fw"
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  settings = <<SETTINGS
    {
        "commandToExecute": "powershell.exe -Command \"${local.powershell_command_disable_fw}\""
    }
SETTINGS
}

