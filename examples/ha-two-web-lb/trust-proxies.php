<?php
// bootstrap/app.php (Laravel 11+): trust X-Forwarded-* from the load balancer only (VPC_CIDR), so
// request()->secure(), URLs and the client IP are right behind it. Never at: '*'.
return Application::configure(basePath: dirname(__DIR__))
    // ->withRouting(...) as before, plus in routes/web.php:
    //   Route::get('/version', fn () => trim((string) @file_get_contents(base_path('REVISION'))));
    ->withMiddleware(function (Middleware $middleware): void {
        $middleware->trustProxies(at: ['10.0.0.0/20']);
    })
    ->create();
