locals {
  db_admin_username = "bbmr_admin"
}

resource "azurerm_resource_group" "cob_performance_rg" {
  name     = "cob-performance-${var.environment}-rg"
  location = var.location
}

resource "azurerm_postgresql_flexible_server" "cob_performance" {
  name                = "cob-performance-${var.environment}"
  resource_group_name = azurerm_resource_group.cob_performance_rg.name
  location            = azurerm_resource_group.cob_performance_rg.location

  version                = "18"
  administrator_login    = local.db_admin_username
  administrator_password = random_password.db_admin.result

  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768

  public_network_access_enabled = true # Locked down through firewall. TODO: BCIT and Infosec review of this approach for security best practices.

  backup_retention_days        = 20
  geo_redundant_backup_enabled = false

  tags = {
    environment = var.environment
    source      = "terraform"
    owner       = "opi-engineering"
  }

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_configuration" "require_ssl" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.cob_performance.id
  value     = "ON"
}

resource "azurerm_postgresql_flexible_server_database" "cob_performance" {
  name      = "cob_performance"
  server_id = azurerm_postgresql_flexible_server.cob_performance.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = true
  }
}

# Firewall rules — only allows db access from incoming connections directly from the internal CDRs in the BCIT VPN network. 
resource "azurerm_postgresql_flexible_server_firewall_rule" "internal_cdr1" {
  name             = "bcit-vpn-cdr1"
  server_id        = azurerm_postgresql_flexible_server.cob_performance.id
  start_ip_address = "192.30.144.0" 
  end_ip_address   = "192.30.144.255"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "internal_cdr2" {
  name             = "bcit-vpn-cdr2"
  server_id        = azurerm_postgresql_flexible_server.cob_performance.id
  start_ip_address = "192.30.145.0" 
  end_ip_address   = "192.30.145.255"
}

