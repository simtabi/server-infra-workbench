<?php
/**
 * config/environments/production.php (Bedrock): the production-only settings.
 * Everything secret comes from the shared .env (600): DB_PASSWORD and the salts, written by app-env.sh.
 */

use Roots\WPConfig\Config;

Config::define('WP_DEBUG', false);
Config::define('WP_DEBUG_DISPLAY', false);
Config::define('SCRIPT_DEBUG', false);
Config::define('DISALLOW_FILE_MODS', true);   // plugins and updates arrive through composer + deploy, not wp-admin
Config::define('DISALLOW_FILE_EDIT', true);
Config::define('AUTOMATIC_UPDATER_DISABLED', true);
Config::define('FORCE_SSL_ADMIN', true);
Config::define('WP_POST_REVISIONS', 10);       // bounded table growth on a small DB droplet
// With the DB manager's TLS_MODE=require for MySQL:
// Config::define('MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL);
ini_set('display_errors', '0');
