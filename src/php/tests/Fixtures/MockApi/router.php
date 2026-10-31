<?php

declare(strict_types=1);

/*
 * A tiny fake of the four provider APIs for `php -S 127.0.0.1:PORT router.php`.
 *
 * Why a real server and not only MockHttpClient: the unit tests prove what the clients ask for; this
 * proves the bytes on the wire through the real Guzzle client: headers, query encoding, JSON and form
 * bodies, Retry-After, redirects. LoopbackHttpClient sends every request here with the original host
 * in X-Mock-Host. Every request is appended to $MOCK_API_STATE/requests.jsonl; the expected token
 * and the service-account public key come from $MOCK_API_STATE/expect.json (generated per test run).
 */
$state = (string) getenv('MOCK_API_STATE');
$expect = json_decode((string) @file_get_contents($state.'/expect.json'), true) ?: [];
$host = $_SERVER['HTTP_X_MOCK_HOST'] ?? '';
$path = (string) parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
parse_str((string) parse_url($_SERVER['REQUEST_URI'], PHP_URL_QUERY), $q);
$method = $_SERVER['REQUEST_METHOD'];
$body = (string) file_get_contents('php://input');
$auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';

file_put_contents($state.'/requests.jsonl', json_encode([
    'host' => $host, 'method' => $method, 'path' => $path, 'query' => $q, 'auth' => $auth,
    'ua' => $_SERVER['HTTP_USER_AGENT'] ?? '', 'type' => $_SERVER['CONTENT_TYPE'] ?? '',
    'accept' => $_SERVER['HTTP_ACCEPT'] ?? '', 'body' => $body,
])."\n", FILE_APPEND | LOCK_EX);

/** @param array<mixed> $json */
function reply(int $status, array $json, array $headers = []): never
{
    http_response_code($status);
    header('Content-Type: application/json');
    foreach ($headers as $k => $v) {
        header("$k: $v");
    }
    echo json_encode($json);
    exit;
}

/** A per-key hit counter, so a route can fail first and succeed on the retry. */
function hit(string $state, string $key): int
{
    $f = $state.'/hits-'.md5($key);
    $n = (int) @file_get_contents($f) + 1;
    file_put_contents($f, (string) $n);

    return $n;
}

$bearer = 'Bearer '.($expect['token'] ?? "\0");

switch ($host) {
    case 'api.digitalocean.com':
        if ($auth !== $bearer) {
            reply(401, ['id' => 'Unauthorized', 'message' => 'Unable to authenticate you']);
        }
        $droplet = static fn (int $id): array => ['id' => $id, 'name' => "web-$id", 'status' => 'active', 'region' => ['slug' => 'nyc3'],
            'size_slug' => 's-1vcpu-2gb', 'memory' => 2048, 'vcpus' => 1, 'disk' => 50, 'tags' => ['web'], 'created_at' => '2026-01-01T00:00:00Z',
            'networks' => ['v4' => [['type' => 'public', 'ip_address' => '203.0.113.'.$id], ['type' => 'private', 'ip_address' => '10.0.0.'.$id]]]];
        if ($path === '/v2/account') {
            if (hit($state, 'do-account') === 1) {
                reply(429, ['id' => 'too_many_requests', 'message' => 'slow down'], ['Retry-After' => '2']);
            }
            reply(200, ['account' => ['email' => 'ops@example.com', 'status' => 'active', 'droplet_limit' => 25, 'uuid' => 'u-1', 'team' => ['x' => 1]]]);
        }
        if ($path === '/v2/droplets') {
            $page = (int) ($q['page'] ?? 1);

            reply(200, ['droplets' => [$droplet($page)], 'links' => $page < 2 ? ['pages' => ['next' => 'https://api.digitalocean.com/v2/droplets?page=2&per_page=1']] : [], 'meta' => ['total' => 2]]);
        }
        if ($path === '/v2/droplets/404') {
            reply(404, ['id' => 'not_found', 'message' => 'The resource you were accessing could not be found.']);
        }
        if ($path === '/v2/droplets/302') {
            http_response_code(302);
            header('Location: https://evil.example.net/steal');
            exit;
        }
        if ($path === '/v2/droplets/7/actions' && $method === 'POST') {
            reply(201, ['action' => ['id' => 99, 'status' => 'in-progress', 'type' => 'snapshot', 'resource_id' => 7, 'started_at' => '2026-01-01T00:00:00Z', 'completed_at' => null]]);
        }
        break;

    case 'ploi.io':
        if ($auth !== $bearer) {
            reply(401, ['message' => 'Unauthenticated.']);
        }
        if ($path === '/api/servers') {
            $page = (int) ($q['page'] ?? 1);
            $row = ['id' => $page, 'name' => "ploi-$page", 'type' => 'server', 'status' => 'active', 'ip_address' => '198.51.100.'.$page,
                'internal_ip' => '10.1.0.'.$page, 'php_version' => '8.5', 'mysql_version' => null, 'sites_count' => $page];
            reply(200, ['data' => [$row], 'meta' => ['current_page' => $page, 'last_page' => 2]]);
        }
        break;

    case 'api.cloudflare.com':
        if ($auth !== $bearer) {
            reply(403, ['success' => false, 'errors' => [['code' => 9109, 'message' => 'Invalid access token']], 'result' => null]);
        }
        if ($path === '/client/v4/zones') {
            if (($q['name'] ?? '') === 'broken.example') {
                reply(200, ['success' => false, 'errors' => [['code' => 1000, 'message' => 'zone lookup failed']], 'result' => []]);
            }
            $page = (int) ($q['page'] ?? 1);
            $zone = ['id' => "z$page", 'name' => "zone$page.example", 'status' => 'active', 'paused' => false, 'plan' => ['name' => 'Free'], 'name_servers' => ['a.ns.example']];
            reply(200, ['success' => true, 'errors' => [], 'result' => [$zone], 'result_info' => ['page' => $page, 'total_pages' => 2]]);
        }
        break;

    case 'oauth2.googleapis.com':
        parse_str($body, $form);
        $jwt = explode('.', (string) ($form['assertion'] ?? ''));
        $ok = count($jwt) === 3 && ($form['grant_type'] ?? '') === 'urn:ietf:params:oauth:grant-type:jwt-bearer'
            && openssl_verify($jwt[0].'.'.$jwt[1], base64_decode(strtr($jwt[2], '-_', '+/')), (string) ($expect['sa_public'] ?? ''), OPENSSL_ALGO_SHA256) === 1;
        $ok ? reply(200, ['access_token' => $expect['token'] ?? '', 'expires_in' => 3600, 'token_type' => 'Bearer'])
            : reply(400, ['error' => 'invalid_grant', 'error_description' => 'Invalid JWT Signature.']);

    case 'compute.googleapis.com':
        if ($auth !== $bearer) {
            reply(401, ['error' => ['code' => 401, 'message' => 'Request had invalid authentication credentials.']]);
        }
        if (preg_match('#^/compute/v1/projects/([a-z0-9-]+)/aggregated/instances$#', $path, $m) === 1) {
            $second = ($q['pageToken'] ?? '') === 'p2';
            $vm = ['id' => $second ? '2' : '1', 'name' => $second ? 'vm-b' : 'vm-a', 'zone' => 'projects/x/zones/us-east1-b', 'status' => 'RUNNING',
                'machineType' => 'zones/us-east1-b/machineTypes/e2-small', 'networkInterfaces' => [['networkIP' => '10.2.0.1']], 'disks' => [], 'labels' => []];
            reply(200, ['items' => ['zones/us-east1-b' => ['instances' => [$vm]], 'zones/us-east1-c' => ['warning' => ['code' => 'NO_RESULTS_ON_PAGE']]]]
                + ($second ? [] : ['nextPageToken' => 'p2']));
        }
        break;
}

reply(404, ['message' => "mock: no route for $method $host$path"]);
