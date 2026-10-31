<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use Simtabi\VpsServerWorkbench\Exception\CredentialException;
use Simtabi\VpsServerWorkbench\Exception\NotFoundException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Keys\AuthorizedKeys;
use Simtabi\VpsServerWorkbench\Keys\KeyApiSpec;
use Simtabi\VpsServerWorkbench\Keys\KeyProviders;
use Simtabi\VpsServerWorkbench\Keys\PublicKey;
use Simtabi\VpsServerWorkbench\Security\Credentials;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\FakeKeys;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\MockHttpClient;
use Simtabi\VpsServerWorkbench\Tests\TestCase;

final class KeysTest extends TestCase
{
    private const array ENV = [
        'DIGITALOCEAN_TOKEN' => 'do-token-abcdef', 'VULTR_API_KEY' => 'vultr-token-abcdef', 'HCLOUD_TOKEN' => 'hcloud-token-abcdef',
        'LINODE_TOKEN' => 'linode-token-abcdef', 'SCW_SECRET_KEY' => 'scw-token-abcdef', 'SCW_PROJECT_ID' => 'proj-0001',
    ];

    /** @param array<string, string> $env */
    private function keys(string $provider, array $env = self::ENV, ?KeyProviders $providers = null): \Simtabi\VpsServerWorkbench\Keys\AccountKeys
    {
        return ($providers ?? new KeyProviders)->make($provider, $this->options(), new Credentials('/nonexistent', $env));
    }

    // ---- public keys ------------------------------------------------------------------------

    public function test_public_key_parse_fingerprint_and_options(): void
    {
        $line = FakeKeys::ed25519('me@laptop');
        $key = PublicKey::parse('from="10.0.0.0/8",no-pty '.$line);
        self::assertSame('ssh-ed25519', $key->type);
        self::assertSame('from="10.0.0.0/8",no-pty', $key->options);
        self::assertSame('me@laptop', $key->comment);
        self::assertSame(FakeKeys::fingerprint($line), $key->fingerprint());
        self::assertMatchesRegularExpression('/^([0-9a-f]{2}:){15}[0-9a-f]{2}$/', $key->md5());
        self::assertSame($line, $key->line());
        self::assertTrue(PublicKey::same($line, 'no-pty '.FakeKeys::ed25519('other comment')));
        self::assertFalse(PublicKey::same($line, FakeKeys::ed25519('x', 2)));
    }

    public function test_public_key_rejects_junk(): void
    {
        foreach (['', '# comment', 'ssh-ed25519', 'ssh-ed25519 short', 'ssh-ed25519 not*base64*at*all*xxxxxxxxxxx', 'ssh-rsa '.base64_encode(pack('N', 11).'ssh-ed25519'.str_repeat('x', 32)),
            'ssh-foo '.base64_encode(str_repeat('y', 40)), '-----BEGIN OPENSSH '.'PRIVATE KEY-----'] as $bad) {
            self::assertNull(PublicKey::tryParse($bad), $bad);
        }
        $this->expectException(ValidationException::class);
        PublicKey::parse('nope');
    }

    // ---- authorized_keys text ---------------------------------------------------------------

    public function test_authorized_keys_add_dedupes_by_key_material_and_keeps_comments(): void
    {
        $a = FakeKeys::ed25519('a', 1);
        $b = FakeKeys::ed25519('b', 2);
        $text = "# managed by hand\n{$a}\n";
        [$same, $added] = AuthorizedKeys::add($text, 'no-pty '.FakeKeys::ed25519('renamed', 1));
        self::assertFalse($added);
        self::assertSame($text, $same);
        [$new, $added] = AuthorizedKeys::add($text, $b);
        self::assertTrue($added);
        self::assertSame("# managed by hand\n{$a}\n{$b}\n", $new);
        self::assertSame(2, AuthorizedKeys::count($new));
        self::assertSame("{$b}\n", AuthorizedKeys::add('', $b)[0]);
    }

    public function test_authorized_keys_remove_is_exact_and_select_by_number_fingerprint_comment(): void
    {
        $a = FakeKeys::ed25519('a', 1);
        $b = FakeKeys::ed25519('b', 2);
        $text = "{$a}\n# keep me\ncommand=\"x\" {$a}\n{$b}\n";
        [$new, $removed] = AuthorizedKeys::remove($text, PublicKey::parse($a));
        self::assertSame(2, $removed);
        self::assertSame("# keep me\n{$b}\n", $new);

        self::assertSame($b, AuthorizedKeys::select($text, '3')['line'] ?? null);
        self::assertSame($b, AuthorizedKeys::select($text, FakeKeys::fingerprint($b))['line'] ?? null);
        self::assertSame($b, AuthorizedKeys::select($text, 'b')['line'] ?? null);
        self::assertNull(AuthorizedKeys::select($text, 'a'), 'ambiguous comment matches nothing');
        self::assertNull(AuthorizedKeys::select($text, '9'));
    }

    // ---- providers --------------------------------------------------------------------------

    public function test_builtins_and_available(): void
    {
        $p = new KeyProviders;
        self::assertSame(['digitalocean', 'vultr', 'hetzner', 'linode', 'scaleway'], $p->names());
        self::assertSame(['digitalocean', 'hetzner'], $p->available(new Credentials('/nonexistent', ['DIGITALOCEAN_TOKEN' => 'x', 'HCLOUD_TOKEN' => 'y', 'SCW_SECRET_KEY' => 'z'])));
        $this->expectException(ValidationException::class);
        $this->expectExceptionMessage('Known providers: digitalocean, hetzner, linode, scaleway, vultr');
        $p->spec('aws');
    }

    public function test_missing_token_and_missing_scaleway_project_are_credential_errors(): void
    {
        try {
            $this->keys('vultr', []);
            self::fail('expected CredentialException');
        } catch (CredentialException $e) {
            self::assertStringContainsString('VULTR_API_KEY', $e->getMessage());
        }
        $this->expectException(CredentialException::class);
        $this->expectExceptionMessage('SCW_PROJECT_ID');
        $this->keys('scaleway', ['SCW_SECRET_KEY' => 'scw-token-abcdef']);
    }

    public function test_digitalocean_list_paginates_and_add_posts(): void
    {
        $line = FakeKeys::ed25519('me@laptop');
        $this->http
            ->json(['ssh_keys' => [['id' => 1, 'name' => 'one', 'public_key' => FakeKeys::ed25519('one', 5), 'fingerprint' => 'aa:bb']], 'links' => ['pages' => ['next' => 'https://api.digitalocean.com/v2/account/keys?page=2&per_page=200']]])
            ->json(['ssh_keys' => [['id' => 2, 'name' => 'two', 'public_key' => FakeKeys::ed25519('two', 6), 'fingerprint' => 'cc:dd']], 'links' => []])
            ->json(['ssh_keys' => [], 'links' => []])
            ->json(['ssh_key' => ['id' => 3, 'name' => 'laptop', 'public_key' => $line, 'fingerprint' => 'ee:ff']], 201);
        $keys = $this->keys('digitalocean');
        self::assertSame(['one', 'two'], array_map(static fn ($k): string => $k->name, $keys->list()));
        $pending = $keys->add('laptop', $line);
        self::assertSame(['name' => 'laptop', 'public_key' => $line], $pending->plan()['payload']);
        $created = $pending->confirm();
        self::assertSame('3', $created->id);
        self::assertSame(['GET /v2/account/keys?per_page=200', 'GET /v2/account/keys?page=2&per_page=200', 'GET /v2/account/keys?per_page=200', 'POST /v2/account/keys'], $this->http->log());
        self::assertSame('Bearer do-token-abcdef', $this->http->last()->getHeaderLine('Authorization'));
    }

    public function test_add_is_a_noop_when_the_key_material_is_already_there(): void
    {
        $line = FakeKeys::ed25519('me@laptop');
        $this->http->json(['ssh_keys' => [['id' => 9, 'name' => 'old name', 'public_key' => FakeKeys::ed25519('different comment')]], 'links' => []]);
        $pending = $this->keys('digitalocean')->add('laptop', $line);
        self::assertTrue($pending->isNoop());
        self::assertSame('9', $pending->confirm()->id);
        self::assertSame(1, count($this->http->requests));
    }

    public function test_vultr_cursor_pagination_patch_rename_and_delete_note(): void
    {
        $this->http
            ->json(['ssh_keys' => [['id' => 'cb676a46-66fd-4dfb-b839-443f2e6c0b60', 'name' => 'a', 'ssh_key' => FakeKeys::ed25519('a')]], 'meta' => ['links' => ['next' => 'bmV4dA==']]])
            ->json(['ssh_keys' => [['id' => 'b2', 'name' => 'b', 'ssh_key' => FakeKeys::ed25519('b', 2)]], 'meta' => ['links' => ['next' => '']]]);
        $keys = $this->keys('vultr');
        $list = $keys->list();
        self::assertSame(FakeKeys::ed25519('a'), $list[0]->publicKey);
        self::assertSame(FakeKeys::fingerprint(FakeKeys::ed25519('a')), $list[0]->displayFingerprint());
        self::assertSame(['GET /v2/ssh-keys?per_page=500', 'GET /v2/ssh-keys?cursor=bmV4dA%3D%3D&per_page=500'], $this->http->log());

        $this->http->json(['ssh_keys' => [['id' => 'b2', 'name' => 'b', 'ssh_key' => FakeKeys::ed25519('b', 2)]], 'meta' => ['links' => ['next' => '']]])->push(new \GuzzleHttp\Psr7\Response(204));
        $rename = $keys->rename('b2', 'renamed');
        self::assertSame(['name' => 'renamed'], $rename->plan()['payload']);
        self::assertTrue($rename->confirm());
        self::assertSame('PATCH /v2/ssh-keys/b2', $this->http->log()[3]);

        $this->http->json(['ssh_keys' => [['id' => 'b2', 'name' => 'b']], 'meta' => ['links' => ['next' => '']]]);
        $remove = $keys->remove('b2');
        self::assertTrue($remove->isDestructive());
        self::assertStringContainsString('servers that already have this key keep it', (string) $remove->plan()['note']);
    }

    public function test_rename_to_same_name_is_noop_and_unknown_id_is_not_found(): void
    {
        $this->http->json(['ssh_keys' => [['id' => 1, 'name' => 'same']], 'meta' => ['pagination' => ['next_page' => null]]]);
        self::assertTrue($this->keys('hetzner')->rename('1', 'same')->isNoop());
        $this->http->json(['ssh_keys' => [], 'meta' => ['pagination' => ['next_page' => null]]]);
        $this->expectException(NotFoundException::class);
        $this->keys('hetzner')->remove('404');
    }

    public function test_hetzner_and_linode_pagination(): void
    {
        $this->http
            ->json(['ssh_keys' => [['id' => 1, 'name' => 'a', 'public_key' => 'x', 'fingerprint' => 'aa']], 'meta' => ['pagination' => ['next_page' => 2]]])
            ->json(['ssh_keys' => [['id' => 2, 'name' => 'b', 'public_key' => 'y', 'fingerprint' => 'bb']], 'meta' => ['pagination' => ['next_page' => null]]]);
        self::assertSame(['aa', 'bb'], array_map(static fn ($k): string => $k->fingerprint, $this->keys('hetzner')->list()));
        self::assertSame(['GET /v1/ssh_keys?per_page=50', 'GET /v1/ssh_keys?page=2&per_page=50'], $this->http->log());

        $this->http
            ->json(['data' => [['id' => 10, 'label' => 'lin-a', 'ssh_key' => 'k']], 'page' => 1, 'pages' => 2])
            ->json(['data' => [['id' => 11, 'label' => 'lin-b', 'ssh_key' => 'k2']], 'page' => 2, 'pages' => 2]);
        self::assertSame(['lin-a', 'lin-b'], array_map(static fn ($k): string => $k->name, $this->keys('linode')->list()));
        self::assertSame(['GET /v4/profile/sshkeys?page_size=100', 'GET /v4/profile/sshkeys?page=2&page_size=100'], array_slice($this->http->log(), 2));
    }

    public function test_linode_create_uses_label_and_root_item(): void
    {
        $line = FakeKeys::ed25519('lin');
        $this->http->json(['data' => [], 'page' => 1, 'pages' => 1])->json(['id' => 77, 'label' => 'lap', 'ssh_key' => $line]);
        $pending = $this->keys('linode')->add('lap', $line);
        self::assertSame(['label' => 'lap', 'ssh_key' => $line], $pending->plan()['payload']);
        self::assertSame('77', $pending->confirm()->id);
    }

    public function test_scaleway_uses_x_auth_token_and_project_scope(): void
    {
        $line = FakeKeys::ed25519('scw');
        $full = array_fill(0, 100, ['id' => 'k', 'name' => 'n', 'public_key' => 'p']);
        $this->http->json(['ssh_keys' => $full])->json(['ssh_keys' => []])->json(['id' => 'new', 'name' => 'lap', 'public_key' => $line]);
        $pending = $this->keys('scaleway')->add('lap', $line);
        self::assertSame(['GET /iam/v1alpha1/ssh-keys?page_size=100&project_id=proj-0001', 'GET /iam/v1alpha1/ssh-keys?page=2&page_size=100&project_id=proj-0001'], $this->http->log());
        self::assertSame('scw-token-abcdef', $this->http->last()->getHeaderLine('X-Auth-Token'));
        self::assertSame('', $this->http->last()->getHeaderLine('Authorization'));
        self::assertSame(['name' => 'lap', 'public_key' => $line, 'project_id' => 'proj-0001'], $pending->plan()['payload']);
        self::assertSame('new', $pending->confirm()->id);
    }

    public function test_token_never_reaches_the_audit_log(): void
    {
        $this->http->json(['ssh_keys' => [], 'links' => []]);
        $this->keys('digitalocean')->add('laptop', FakeKeys::ed25519('x'))->plan();
        self::assertStringNotContainsString('do-token-abcdef', print_r($this->audit->entries, true));
    }

    // ---- extra providers from config ---------------------------------------------------------

    public function test_extra_provider_from_config_file(): void
    {
        $dir = $this->tempDir();
        file_put_contents($dir.'/keys.json', json_encode(['extra_providers' => [
            ['name' => 'acme', 'base_url' => 'https://api.acme.test/v1', 'token_env' => 'ACME_TOKEN', 'list_path' => '/keys', 'list_field' => 'items',
                'delete_path' => '/keys/{id}', 'auth_header_name' => 'X-Api-Key', 'auth_header_prefix' => '', 'extra_headers' => ['X-Client' => 'workbench']],
            ['name' => 'digitalocean', 'base_url' => 'https://evil.test', 'token_env' => 'DIGITALOCEAN_TOKEN', 'list_path' => '/k', 'list_field' => 'k'],
        ]], JSON_THROW_ON_ERROR));
        $providers = KeyProviders::load($dir.'/keys.json');
        self::assertSame('https://api.digitalocean.com/v2', $providers->spec('digitalocean')->baseUrl, 'built-ins win');
        $this->http->json(['items' => [['id' => 5, 'name' => 'x', 'public_key' => 'k']]]);
        $list = $this->keys('acme', ['ACME_TOKEN' => 'acme-token-abcdef'], $providers)->list();
        self::assertSame('5', $list[0]->id);
        self::assertSame('acme-token-abcdef', $this->http->last()->getHeaderLine('X-Api-Key'));
        self::assertSame('workbench', $this->http->last()->getHeaderLine('X-Client'));
        self::assertSame('GET /v1/keys', $this->http->log()[0]);
        self::assertSame(['acme'], array_values(array_diff($providers->names(), array_keys(KeyProviders::builtins()))));
    }

    public function test_extra_provider_rename_unsupported_and_root_list(): void
    {
        $spec = KeyApiSpec::fromConfig(['name' => 'flat', 'base_url' => 'https://api.flat.test', 'token_env' => 'FLAT_TOKEN', 'list_path' => '/keys', 'list_field' => '']);
        $providers = new KeyProviders([$spec]);
        $this->http->json([['id' => 1, 'name' => 'a', 'public_key' => 'p']]);
        $keys = $this->keys('flat', ['FLAT_TOKEN' => 'flat-token-abcdef'], $providers);
        self::assertSame('a', $keys->list()[0]->name);
        $this->expectException(ValidationException::class);
        $this->expectExceptionMessage("rename isn't configured");
        $keys->rename('1', 'b');
    }

    /** @return iterable<string, array{array<mixed>, string}> */
    public static function badConfigs(): iterable
    {
        $ok = ['name' => 'x', 'base_url' => 'https://api.x.test', 'token_env' => 'X_TOKEN', 'list_path' => '/k', 'list_field' => 'k'];
        yield 'http only' => [['base_url' => 'http://api.x.test'] + $ok, 'https://'];
        yield 'missing list_field' => [array_diff_key($ok, ['list_field' => 1]), '"list_field" is required'];
        yield 'unknown field' => [$ok + ['typo_field' => 1], 'unknown field(s) typo_field'];
        yield 'bad token env' => [['token_env' => 'lower'] + $ok, 'UPPER_CASE'];
        yield 'bad pagination' => [['pagination' => 'magic'] + $ok, 'pagination must be one of'];
        yield 'bad header' => [['auth_header_name' => "X\nY"] + $ok, 'not a valid header name'];
    }

    /** @param array<mixed> $entry */
    #[\PHPUnit\Framework\Attributes\DataProvider('badConfigs')]
    public function test_bad_extra_provider_entries_are_rejected(array $entry, string $message): void
    {
        $this->expectException(ValidationException::class);
        $this->expectExceptionMessage($message);
        KeyApiSpec::fromConfig($entry);
    }

    public function test_broken_config_json_and_missing_file(): void
    {
        self::assertSame(5, count(KeyProviders::load('/nonexistent/keys.json')->names()));
        $dir = $this->tempDir();
        file_put_contents($dir.'/keys.json', '{nope');
        $this->expectException(ValidationException::class);
        $this->expectExceptionMessage("isn't valid JSON");
        KeyProviders::load($dir.'/keys.json');
    }

    public function test_paths_are_validated_before_any_request(): void
    {
        $this->http->json(['ssh_keys' => [['id' => '../x', 'name' => 'a']], 'links' => []]);
        $this->expectException(ValidationException::class);
        $this->keys('digitalocean')->remove('../x');
    }

    public function test_mock_body_helper_is_used(): void
    {
        $line = FakeKeys::ed25519('x');
        $this->http->json(['ssh_keys' => [], 'links' => []])->json(['ssh_key' => ['id' => 1]]);
        $this->keys('digitalocean')->add('x', $line)->confirm();
        self::assertSame($line, MockHttpClient::body($this->http->last())['public_key']);
    }
}
