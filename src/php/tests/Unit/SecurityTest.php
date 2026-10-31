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
        $value = self::secret();
        $secret = new Secret($value);

        self::assertSame('***', (string) $secret);
        self::assertSame('"***"', json_encode($secret));
        self::assertStringNotContainsString($value, print_r($secret, true));
        self::assertStringNotContainsString($value, var_export(['s' => (string) $secret], true));
        self::assertSame($value, $secret->reveal());

        $this->expectException(\LogicException::class);
        serialize($secret);
    }

    public function test_redactor_masks_known_secrets_and_credential_shapes(): void
    {
        [$known, $query, $pw, $key, $pem] = [self::secret('known-'), self::secret('q'), self::secret('pw-'), self::secret('k-'), 'MII'.bin2hex(random_bytes(8))];
        $bearer = bin2hex(random_bytes(4)).'.'.bin2hex(random_bytes(4)).'.'.bin2hex(random_bytes(4));
        $google = 'ya29.'.bin2hex(random_bytes(10));
        $r = (new Redactor)->withSecret($known);
        $text = $r->redact(implode("\n", [
            "url ?token={$query}&x=1",
            "Authorization: Bearer {$bearer}",
            "value {$known} and ".rawurlencode($known),
            'do '.self::token(),
            json_encode(['password' => $pw, 'api_key' => $key]),
            '-----BEGIN '."PRIVATE KEY-----\n{$pem}\n-----END ".'PRIVATE KEY-----',
            "google {$google}",
        ]));

        foreach ([$query, $bearer, $known, self::token(), $pw, $key, $pem, $google] as $leak) {
            self::assertStringNotContainsString($leak, $text);
        }
        self::assertStringContainsString('x=1', $text);
        self::assertStringContainsString('Bearer ***', $text);
    }

    public function test_redactor_masks_sensitive_keys_in_arrays(): void
    {
        $out = (new Redactor)->redactArray(['name' => 'db', 'nested' => ['client_secret' => self::secret(), 'ok' => 1], 'token' => self::secret()]);

        self::assertSame(['name' => 'db', 'nested' => ['client_secret' => '***', 'ok' => 1], 'token' => '***'], $out);
    }

    public function test_redacting_logger_wraps_any_psr3_logger(): void
    {
        $inner = new MemoryLogger;
        $pw = self::secret('pw-');
        (new RedactingLogger($inner, (new Redactor)->withSecret(self::fake('s3cr3t'))))->info('using '.self::fake('s3cr3t'), ['password' => $pw, 'n' => 'ok']);

        self::assertStringNotContainsString(self::fake('s3cr3t'), $inner->all());
        self::assertStringNotContainsString($pw, $inner->all());
        self::assertStringContainsString('"ok"', $inner->all());
    }

    public function test_credentials_prefer_env_then_file(): void
    {
        $dir = $this->tempDir();
        $file = $dir.'/credentials';
        file_put_contents($file, "# comment\nexport PLOI_API_TOKEN=\"from-file\"\nCLOUDFLARE_API_TOKEN=cf-file # trailing\nDIGITALOCEAN_TOKEN=file-do\n");
        chmod($file, 0o600);

        $store = new Credentials($file, ['DIGITALOCEAN_TOKEN' => self::fake('env-do')]);

        self::assertSame(self::fake('env-do'), $store->get('DIGITALOCEAN_TOKEN')->reveal());
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
        file_put_contents($file, 'PLOI_API_TOKEN='.self::secret()."\n");
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
        file_put_contents($file, 'PLOI_API_TOKEN='.self::secret()."\n");
        chmod($file, 0o600);

        $this->expectException(CredentialException::class);
        $this->expectExceptionMessageMatches('/git working tree/');
        (new Credentials($file, []))->get('PLOI_API_TOKEN');
    }

    public function test_missing_credential_says_where_to_put_it_without_values(): void
    {
        $other = self::secret('value-');
        try {
            (new Credentials('/nonexistent/file', ['OTHER' => $other]))->get('PLOI_API_TOKEN');
            self::fail('expected an exception');
        } catch (CredentialException $e) {
            self::assertStringContainsString('PLOI_API_TOKEN is not set', $e->getMessage());
            self::assertStringNotContainsString($other, $e->getMessage());
        }
    }

    public function test_explicit_value_wins_in_resolve(): void
    {
        [$given, $env] = [self::secret('given-'), self::secret('env-')];
        self::assertSame($given, Credentials::resolve($given, 'PLOI_API_TOKEN', new Credentials(null, ['PLOI_API_TOKEN' => $env]))->reveal());
        self::assertSame($env, Credentials::resolve(null, 'PLOI_API_TOKEN', new Credentials(null, ['PLOI_API_TOKEN' => $env]))->reveal());
    }
}
