<?php

// config/database.php -> 'connections' => [ ... 'tenant' => require __DIR__.'/tenant-connection.php', ]
// The tenant database name is set at runtime (e.g. by a tenancy package or middleware):
//   config(['database.connections.tenant.database' => sprintf('%s_%s_t_%d', 'shop', app()->environment('production') ? 'prd' : 'dev', $tenant->id)]);
//   DB::purge('tenant');
// Credentials come only from .env (written by `bin/workbench env init`, values generated, mode 600).

return [
    'driver' => 'pgsql',
    'host' => env('DB_HOST', '127.0.0.1'),
    'port' => env('DB_PORT', '6432'),
    'database' => null,
    'username' => env('DB_USERNAME'),
    'password' => env('DB_PASSWORD'),
    'charset' => 'utf8',
    'prefix' => '',
    'search_path' => 'public',
    'sslmode' => env('DB_SSLMODE', 'prefer'),
];
