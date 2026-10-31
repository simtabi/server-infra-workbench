<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use GuzzleHttp\Psr7\Response;
use Psr\Http\Message\RequestInterface;
use Simtabi\VpsServerWorkbench\Exception\ActionFailedException;
use Simtabi\VpsServerWorkbench\Exception\AuthenticationException;
use Simtabi\VpsServerWorkbench\Exception\CredentialException;
use Simtabi\VpsServerWorkbench\Gcp\Auth\GoogleOAuth;
use Simtabi\VpsServerWorkbench\Gcp\Auth\ServiceAccountTokenProvider;
use Simtabi\VpsServerWorkbench\Gcp\Auth\StaticTokenProvider;
use Simtabi\VpsServerWorkbench\Gcp\Data\InstanceStatus;
use Simtabi\VpsServerWorkbench\Gcp\Gcp;
use Simtabi\VpsServerWorkbench\Security\Credentials;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

final class GcpTest extends TestCase
{
    /**
     * A throwaway key generated in memory for this test run; no key file is ever read.
     *
     * @return array{string, string}
     */
    private static function keyPair(): array
    {
        $key = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
        self::assertNotFalse($key);
        openssl_pkey_export($key, $pem);
        $details = openssl_pkey_get_details($key);
        self::assertIsArray($details);
        self::assertIsString($pem);
        self::assertIsString($details['key']);

        return [$pem, $details['key']];
    }

    /**
     * @param list<mixed> $scopes
     * @return \Closure(RequestInterface): Response
     */
    private function tokenEndpoint(string $publicKey, array &$scopes): \Closure
    {
        return static function (RequestInterface $request) use ($publicKey, &$scopes): Response {
            parse_str((string) $request->getBody(), $form);
            self::assertSame('urn:ietf:params:oauth:grant-type:jwt-bearer', $form['grant_type'] ?? null);
            $assertion = $form['assertion'] ?? '';
            self::assertIsString($assertion);
            [$h, $p, $s] = explode('.', $assertion);
            $b64 = static fn (string $v): string => (string) base64_decode(strtr($v, '-_', '+/'), true);
            self::assertSame(1, openssl_verify("{$h}.{$p}", $b64($s), $publicKey, OPENSSL_ALGO_SHA256), 'JWT must be RS256-signed by the service account key');
            $claims = json_decode($b64($p), true, flags: JSON_THROW_ON_ERROR);
            self::assertIsArray($claims);
            self::assertSame('robot@proj-123.iam.gserviceaccount.com', $claims['iss']);
            self::assertSame('https://oauth2.googleapis.com/token', $claims['aud']);
            $scopes[] = $claims['scope'];

            return new Response(200, [], json_encode(['access_token' => $claims['scope'] === GoogleOAuth::SCOPE_WRITE ? 'ya29'.'.write-token' : 'ya29'.'.read-token', 'expires_in' => 3599], JSON_THROW_ON_ERROR));
        };
    }

    public function test_service_account_uses_readonly_scope_for_reads_and_compute_for_writes(): void
    {
        [$private, $public] = self::keyPair();
        $scopes = [];
        $tokens = ServiceAccountTokenProvider::fromArray([
            'type' => 'service_account', 'project_id' => 'proj-123', 'client_email' => 'robot@proj-123.iam.gserviceaccount.com',
            'private_key' => $private, 'token_uri' => 'https://oauth2.googleapis.com/token',
        ], $this->options());

        $this->http
            ->push($this->tokenEndpoint($public, $scopes))
            ->json(['items' => [
                'zones/us-east1-b' => ['instances' => [[
                    'id' => '42', 'name' => 'db-1', 'zone' => 'https://x/zones/us-east1-b', 'status' => 'RUNNING', 'machineType' => 'https://x/machineTypes/e2-medium',
                    'networkInterfaces' => [['networkIP' => '10.0.0.2', 'accessConfigs' => [['natIP' => '34.1.2.3']]]],
                    'disks' => [['source' => 'https://x/disks/db-1']],
                ]]],
                'zones/us-west1-a' => ['warning' => ['code' => 'NO_RESULTS_ON_PAGE']],
            ], 'nextPageToken' => 'p2'])
            ->json(['items' => []]);

        $gcp = Gcp::make(null, $tokens, $this->options(), new Credentials(null, []));
        $instances = $gcp->instances()->list();

        self::assertSame('proj-123', $gcp->project());
        self::assertCount(1, $instances);
        self::assertSame(InstanceStatus::Running, $instances[0]->status);
        self::assertSame(['e2-medium', 'us-east1-b', '34.1.2.3', ['db-1']], [$instances[0]->machineType, $instances[0]->zone, $instances[0]->externalIp, $instances[0]->disks]);
        self::assertSame('Bearer ya29'.'.read-token', $this->http->requests[1]->getHeaderLine('Authorization'));
        self::assertStringContainsString('pageToken=p2', $this->http->requests[2]->getUri()->getQuery());
        self::assertSame([GoogleOAuth::SCOPE_READ], $scopes, 'the read token is cached across pages');

        $this->http
            ->push($this->tokenEndpoint($public, $scopes))
            ->json(['name' => 'op-1', 'status' => 'RUNNING', 'zone' => 'https://x/zones/us-east1-b', 'operationType' => 'createSnapshot'])
            ->json(['name' => 'op-1', 'status' => 'DONE', 'zone' => 'https://x/zones/us-east1-b', 'operationType' => 'createSnapshot']);

        $op = $gcp->snapshots()->create('us-east1-b', 'db-1', 'pre-upgrade')->confirm()->wait();

        self::assertTrue($op->isDone());
        self::assertSame([GoogleOAuth::SCOPE_READ, GoogleOAuth::SCOPE_WRITE], $scopes);
        self::assertSame('Bearer ya29'.'.write-token', $this->http->requests[4]->getHeaderLine('Authorization'));
        self::assertSame('/compute/v1/projects/proj-123/zones/us-east1-b/disks/db-1/createSnapshot', $this->http->requests[4]->getUri()->getPath());
        self::assertSame('/compute/v1/projects/proj-123/zones/us-east1-b/operations/op-1', $this->http->requests[5]->getUri()->getPath());
        self::assertStringNotContainsString('ya29.', $this->logger->all());
    }

    public function test_token_errors_are_authentication_errors(): void
    {
        [$private] = self::keyPair();
        $tokens = ServiceAccountTokenProvider::fromArray(['type' => 'service_account', 'client_email' => 'a@b.iam.gserviceaccount.com', 'private_key' => $private], $this->options());
        $this->http->json(['error' => 'invalid_grant', 'error_description' => 'Invalid JWT Signature.'], 400);

        $this->expectException(AuthenticationException::class);
        $this->expectExceptionMessageMatches('/Invalid JWT Signature/');
        $tokens->token(GoogleOAuth::SCOPE_READ);
    }

    public function test_key_file_must_be_private_and_outside_repos(): void
    {
        $dir = $this->tempDir();
        $file = $dir.'/sa.json';
        file_put_contents($file, '{"type":"service_account"}');
        chmod($file, 0o644);

        try {
            ServiceAccountTokenProvider::fromFile($file, $this->options());
            self::fail('accepted a world-readable key');
        } catch (CredentialException $e) {
            self::assertStringContainsString('chmod 600', $e->getMessage());
        }

        mkdir($dir.'/.git');
        chmod($file, 0o600);
        $this->expectException(CredentialException::class);
        $this->expectExceptionMessageMatches('/git working tree/');
        ServiceAccountTokenProvider::fromFile($file, $this->options());
    }

    public function test_lists_firewalls_and_flags_world_open_rules(): void
    {
        $this->http->json(['items' => [
            ['name' => 'allow-ssh', 'network' => 'x/networks/default', 'direction' => 'INGRESS', 'sourceRanges' => ['0.0.0.0/0'], 'allowed' => [['IPProtocol' => 'tcp', 'ports' => ['22']]]],
            ['name' => 'allow-db', 'network' => 'x/networks/default', 'sourceRanges' => ['10.0.0.0/8'], 'allowed' => [['IPProtocol' => 'tcp', 'ports' => ['5432']]]],
        ]]);

        $rules = Gcp::make('proj-123', new StaticTokenProvider('ya29'.'.static'), $this->options(), new Credentials(null, []))->firewalls()->list();

        self::assertSame(['tcp:22', true], [$rules[0]->allowed[0], $rules[0]->isOpenToWorld()]);
        self::assertFalse($rules[1]->isOpenToWorld());
    }

    public function test_failed_operation_throws(): void
    {
        $this->http
            ->json(['name' => 'op-2', 'status' => 'DONE', 'operationType' => 'createSnapshot', 'zone' => 'z/zones/us-east1-b', 'error' => ['errors' => [['message' => 'Quota exceeded']]]]);

        $this->expectException(ActionFailedException::class);
        $this->expectExceptionMessageMatches('/Quota exceeded/');
        Gcp::make('proj-123', new StaticTokenProvider('ya29'.'.static'), $this->options(), new Credentials(null, []))
            ->snapshots()->create('us-east1-b', 'db-1')->confirm()->wait();
    }

    public function test_needs_a_project(): void
    {
        $this->expectException(CredentialException::class);
        Gcp::make(null, new StaticTokenProvider('ya29'.'.static'), $this->options(), new Credentials(null, []));
    }
}
