<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use Simtabi\VpsServerWorkbench\Exception\CredentialException;
use Simtabi\VpsServerWorkbench\Security\Credentials;
use Simtabi\VpsServerWorkbench\Security\RedactingLogger;
use Simtabi\VpsServerWorkbench\Security\Redactor;
use Simtabi\VpsServerWorkbench\Security\Secret;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\MemoryLogger;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

final class SecurityTest extends TestCase
{
    public function test_secret_never_prints_its_value(): void
    {
        $secret = new Secret('super-secret-value');

        self::assertSame('***', (string) $secret);
        self::assertSame('"***"', json_encode($secret));
        self::assertStringNotContainsString('super-secret-value', print_r($secret, true));
        self::assertStringNotContainsString('super-secret-value', var_export(['s' => (string) $secret], true));
        self::assertSame('super-secret-value', $secret->reveal());

        $this->expectException(\LogicException::class);
        serialize($secret);
    }

    public function test_redactor_masks_known_secrets_and_credential_shapes(): void
    {
        $r = (new Redactor)->withSecret('my-known-token-123');
        $text = $r->redact(implode("\n", [
            'url ?token=abc123&x=1',
            'Authorization: Bearer abc.def.ghi',
            'value my-known-token-123 and '.rawurlencode('my-known-token-123'),
            'do '.self::TOKEN,
            '{"password":"hunter2","api_key": "k-1"}',
            '-----BEGIN '."PRIVATE KEY-----\nMIIabc\n-----END ".'PRIVATE KEY-----',
            'google ya29'.'.a0AfB_byC-xyz',
        ]));

        foreach (['abc123', 'abc.def.ghi', 'my-known-token-123', self::TOKEN, 'hunter2', 'k-1', 'MIIabc', 'ya29'.'.a0'] as $leak) {
            self::assertStringNotContainsString($leak, $text);
        }
        self::assertStringContainsString('x=1', $text);
        self::assertStringContainsString('Bearer ***', $text);
    }

    public function test_redactor_masks_sensitive_keys_in_arrays(): void
    {
        $out = (new Redactor)->redactArray(['name' => 'db', 'nested' => ['client_secret' => 'zzz', 'ok' => 1], 'token' => 'abc']);

        self::assertSame(['name' => 'db', 'nested' => ['client_secret' => '***', 'ok' => 1], 'token' => '***'], $out);
    }

    public function test_redacting_logger_wraps_any_psr3_logger(): void
    {
        $inner = new MemoryLogger;
        (new RedactingLogger($inner, (new Redactor)->withSecret('s3cr3t-value')))->info('using s3cr3t-value', ['password' => 'p', 'n' => 'ok']);

        self::assertStringNotContainsString('s3cr3t-value', $inner->all());
        self::assertStringNotContainsString('"p"', $inner->all());
        self::assertStringContainsString('"ok"', $inner->all());
    }

    public function test_credentials_prefer_env_then_file(): void
    {
        $dir = $this->tempDir();
        $file = $dir.'/credentials';
        file_put_contents($file, "# comment\nexport PLOI_API_TOKEN=\"from-file\"\nCLOUDFLARE_API_TOKEN=cf-file # trailing\nDIGITALOCEAN_TOKEN=file-do\n");
        chmod($file, 0o600);

        $store = new Credentials($file, ['DIGITALOCEAN_TOKEN' => 'env-do']);

        self::assertSame('env-do', $store->get('DIGITALOCEAN_TOKEN')->reveal());
        self::assertSame('env', $store->source('DIGITALOCEAN_TOKEN'));
        self::assertSame('from-file', $store->get('PLOI_API_TOKEN')->reveal());
        self::assertSame('cf-file', $store->get('CLOUDFLARE_API_TOKEN')->reveal());
        self::assertSame('file', $store->source('PLOI_API_TOKEN'));
        self::assertNull($store->source('GCP_PROJECT'));
        self::assertSame([], $store->fileProblems());
    }

    public function test_credentials_file_must_be_private(): void
    {
        $dir = $this->tempDir();
        $file = $dir.'/credentials';
        file_put_contents($file, "PLOI_API_TOKEN=leaky\n");
        chmod($file, 0o644);

        $store = new Credentials($file, []);
        self::assertStringContainsString('chmod 600', implode(' ', $store->fileProblems()));

        $this->expectException(CredentialException::class);
        $this->expectExceptionMessageMatches('/chmod 600/');
        $store->get('PLOI_API_TOKEN');
    }

    public function test_credentials_file_inside_a_git_repo_is_refused(): void
    {
        $dir = $this->tempDir();
        mkdir($dir.'/.git');
        $file = $dir.'/credentials';
        file_put_contents($file, "PLOI_API_TOKEN=x\n");
        chmod($file, 0o600);

        $this->expectException(CredentialException::class);
        $this->expectExceptionMessageMatches('/git working tree/');
        (new Credentials($file, []))->get('PLOI_API_TOKEN');
    }

    public function test_missing_credential_says_where_to_put_it_without_values(): void
    {
        try {
            (new Credentials('/nonexistent/file', ['OTHER' => 'value-123']))->get('PLOI_API_TOKEN');
            self::fail('expected an exception');
        } catch (CredentialException $e) {
            self::assertStringContainsString('PLOI_API_TOKEN is not set', $e->getMessage());
            self::assertStringNotContainsString('value-123', $e->getMessage());
        }
    }

    public function test_explicit_value_wins_in_resolve(): void
    {
        self::assertSame('given', Credentials::resolve('given', 'PLOI_API_TOKEN', new Credentials(null, ['PLOI_API_TOKEN' => 'env']))->reveal());
        self::assertSame('env', Credentials::resolve(null, 'PLOI_API_TOKEN', new Credentials(null, ['PLOI_API_TOKEN' => 'env']))->reveal());
    }
}
