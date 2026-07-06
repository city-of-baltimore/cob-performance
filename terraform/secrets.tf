data "azurerm_client_config" "current" {}

resource "random_password" "db_admin" {
  length           = 32
  special          = true
  override_special = "_%@!"
}

resource "azurerm_key_vault" "cob_performance_kv" {
  name                = "cob-performance-kv-${var.environment}"
  resource_group_name = azurerm_resource_group.cob_performance_rg.name
  location            = azurerm_resource_group.cob_performance_rg.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  tags = {
    environment = var.environment
    source      = "terraform"
    owner       = "opi-engineering"
  }
}

resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.cob_performance_kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Set",
    "Get",
    "List",
    "Delete",
  ]
}

resource "azurerm_key_vault_secret" "db_admin_username" {
  name         = "db-admin-username"
  value        = local.db_admin_username
  key_vault_id = azurerm_key_vault.cob_performance_kv.id

  depends_on = [azurerm_key_vault_access_policy.deployer]
}

resource "azurerm_key_vault_secret" "db_admin_password" {
  name         = "db-admin-password"
  value        = random_password.db_admin.result
  key_vault_id = azurerm_key_vault.cob_performance_kv.id

  depends_on = [azurerm_key_vault_access_policy.deployer]
}

resource "azurerm_key_vault_secret" "db_connection_string" {
  name = "db-connection-string"
  value = format(
    "postgresql://%s:%s@%s:5432/%s?sslmode=require",
    local.db_admin_username,
    random_password.db_admin.result,
    azurerm_postgresql_flexible_server.cob_performance.fqdn,
    azurerm_postgresql_flexible_server_database.cob_performance.name,
  )
  key_vault_id = azurerm_key_vault.cob_performance_kv.id

  depends_on = [azurerm_key_vault_access_policy.deployer]
}