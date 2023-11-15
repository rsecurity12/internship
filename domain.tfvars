resource_prefix = "PurpleLab"

node_location_dc   = "northeurope"
node_location_workstation =   "northeurope" # "westeurope"
vmsize_dc = "Standard_D2s_v3"
vmsize_workstation ="Standard_D2s_v4"


active_directory_domain = "enterprises.com"
active_directory_netbios_name = "ENTERPRISES"
domadminuser = "adminuser"
domadminpassword = "Password1!"
safemode_password = "Password1!"

adminuser = "adminuser"
adminpassword = "Password1!"

tags = {
  "Environment" = "lab"
  "Customer" = "lab"
}