<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Unit;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Github\Github;
use Simtabi\ServerInfraWorkbench\Github\GithubPaginator;
use Simtabi\ServerInfraWorkbench\Github\Repository;
use Simtabi\ServerInfraWorkbench\Github\Secrets;
use Simtabi\ServerInfraWorkbench\Security\Secret;
use Simtabi\ServerInfraWorkbench\Tests\Fixtures\MockHttpClient;
use Simtabi\ServerInfraWorkbench\Tests\TestCase;

/** GitHub REST: headers, Link pagination, libsodium secrets, deploy keys, workflows, releases. No network. */
final class GithubTest extends TestCase
{
    private function github(): Github
    {
        return Github::make(self::fake('gh'), $this->options());
    }

    public function test_sends_versioned_headers_and_follows_link_pagination(): void
    {
        $this->http
            ->json([['full_name' => 'acme/a', 'private' => true, 'visibility' => 'private', 'default_branch' => 'main']], 200,
                ['Link' => '<https://api.github.com/user/repos?per_page=100&page=2>; rel="next", <https://api.github.com/user/repos?per_page=100&page=2>; rel="last"'])
            ->json([['full_name' => 'acme/b', 'private' => false, 'visibility' => 'public', 'default_branch' => 'trunk']]);

        $repos = $this->github()->repositories();

        self::assertSame(['acme/a', 'acme/b'], array_map(static fn ($r): string => $r->string('fullName'), $repos));
        self::assertStringContainsString('page=2', $this->http->log()[1]);
        $request = $this->http->requests[0];
        self::assertSame('Bearer '.self::fake('gh'), $request->getHeaderLine('Authorization'));
        self::assertSame(Github::API_VERSION, $request->getHeaderLine('X-GitHub-Api-Version'));
        self::assertSame('application/vnd.github+json', $request->getHeaderLine('Accept'));
        self::assertSame('api.github.com', $request->getUri()->getHost());
    }

    public function test_link_parser_ignores_other_relations(): void
    {
        self::assertNull(GithubPaginator::nextUrl('<https://api.github.com/x?page=1>; rel="prev"'));
        self::assertSame('https://api.github.com/x?page=3', GithubPaginator::nextUrl('<https://api.github.com/x?page=1>; rel="prev", <https://api.github.com/x?page=3>; rel="next"'));
    }

    public function test_exhausted_quota_403_is_retried_after_the_reset(): void
    {
        $reset = (string) (time() + 2);
        $this->http
            ->json(['message' => 'API rate limit exceeded'], 403, ['x-ratelimit-limit' => '5000', 'x-ratelimit-remaining' => '0', 'x-ratelimit-reset' => $reset])
            ->json(['login' => 'octo', 'id' => 1], 200, ['x-ratelimit-limit' => '5000', 'x-ratelimit-remaining' => '4999']);

        self::assertSame('octo', $this->github()->user()->string('login'));
        self::assertCount(2, $this->http->requests);
        self::assertNotEmpty($this->sleeper->sleeps);
    }

    public function test_secret_is_sealed_at_confirm_and_never_in_the_plan(): void
    {
        $pair = sodium_crypto_box_keypair();
        $value = self::secret('val-');
        $this->http
            ->json(['key_id' => 'kid-1', 'key' => base64_encode(sodium_crypto_box_publickey($pair))])
            ->json(null, 201);

        $action = $this->github()->repo('acme/app')->secrets()->set('DEPLOY_TOKEN', new Secret($value));
        $shown = json_encode($action->plan(), JSON_THROW_ON_ERROR).$action->describe();
        self::assertStringNotContainsString($value, $shown);
        self::assertSame([], $this->http->requests, 'nothing is sent before confirm');

        self::assertTrue($action->confirm());
        self::assertSame(['GET /repos/acme/app/actions/secrets/public-key', 'PUT /repos/acme/app/actions/secrets/DEPLOY_TOKEN'], $this->http->log());
        $body = MockHttpClient::body($this->http->last());
        self::assertSame('kid-1', $body['key_id']);
        self::assertIsString($body['encrypted_value']);
        self::assertStringNotContainsString($value, (string) $this->http->last()->getBody());
        self::assertSame($value, sodium_crypto_box_seal_open((string) base64_decode($body['encrypted_value'], true), $pair));
    }

    public function test_environment_secrets_and_name_rules(): void
    {
        $pair = sodium_crypto_box_keypair();
        $this->http->json(['key_id' => 'k', 'key' => base64_encode(sodium_crypto_box_publickey($pair))])->json(null, 204);
        $this->github()->repo('acme/app')->secrets('production')->set('DB_URL', new Secret(self::secret()))->confirm();
        self::assertSame('PUT /repos/acme/app/environments/production/secrets/DB_URL', $this->http->log()[1]);

        foreach (['GITHUB_TOKEN', '1BAD', 'has-dash', ''] as $bad) {
            try {
                Secrets::name($bad);
                self::fail($bad);
            } catch (ValidationException) {
                $this->addToAssertionCount(1);
            }
        }
        $this->expectException(ValidationException::class);
        $this->github()->repo('acme/app')->secrets()->set('BIG', new Secret(str_repeat('x', 49 * 1024)));
    }

    public function test_deploy_keys_are_read_only_unless_write_which_is_destructive(): void
    {
        $key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA'.bin2hex(random_bytes(16)).' ci@example';
        $this->http->json([])->json([]);
        $keys = $this->github()->repo('acme/app')->deployKeys();
        $ro = $keys->add('ci', $key);
        self::assertFalse($ro->isDestructive());
        self::assertTrue($ro->plan()['payload']['read_only']);
        self::assertTrue($keys->add('ci', $key, false)->isDestructive());
    }

    public function test_workflow_dispatch_runs_and_releases(): void
    {
        $wf = $this->github()->repo('acme/app')->workflows();
        $dispatch = $wf->dispatch('deploy.yml', 'main', ['env' => 'staging']);
        self::assertSame(['ref' => 'main', 'inputs' => ['env' => 'staging']], $dispatch->plan()['payload']);
        $this->http->json(null, 204);
        self::assertTrue($dispatch->confirm());
        self::assertSame('POST /repos/acme/app/actions/workflows/deploy.yml/dispatches', $this->http->log()[0]);

        $this->http->json(['total_count' => 1, 'workflow_runs' => [['id' => 9, 'name' => 'CI', 'head_branch' => 'main', 'status' => 'completed', 'conclusion' => 'success']]]);
        $runs = $wf->runs(null, 'main', 'completed', 5);
        self::assertSame(9, $runs[0]->int('id'));
        self::assertStringContainsString('branch=main', $this->http->log()[1]);

        foreach ([fn () => $wf->dispatch('../x', 'main'), fn () => $wf->dispatch('ci.yml', 'main;rm'), fn () => $wf->runs(null, null, 'bogus')] as $bad) {
            try {
                $bad();
                self::fail('accepted bad input');
            } catch (ValidationException) {
                $this->addToAssertionCount(1);
            }
        }

        $this->http->json([]);
        $release = $this->github()->repo('acme/app')->releases()->create('v1.2.3', 'main', 'v1.2.3', 'notes', true);
        self::assertSame('v1.2.3', $release->plan()['payload']['tag_name']);
        self::assertTrue($this->github()->repo('acme/app')->releases()->delete(5)->isDestructive());
    }

    public function test_repository_names_are_validated(): void
    {
        self::assertSame('/repos/acme/app/releases', Repository::parse('acme/app')->path('releases'));
        $this->expectException(ValidationException::class);
        Repository::parse('acme/../etc');
    }
}
