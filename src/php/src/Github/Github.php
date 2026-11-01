<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Github;

use Simtabi\ServerInfraWorkbench\Http\BearerToken;
use Simtabi\ServerInfraWorkbench\Http\ClientOptions;
use Simtabi\ServerInfraWorkbench\Http\Endpoint;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Security\Credentials;
use Simtabi\ServerInfraWorkbench\Security\Secret;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Item;

/**
 * GitHub REST API (version 2022-11-28) with a fine-grained personal access token, limited to the
 * repositories it needs (see docs/providers/github.md for the exact permissions per command).
 *
 *     Github::make()->repo('acme/site')->workflows()->dispatch('deploy.yml', 'main')->confirm();
 *     Github::make()->repo('acme/site')->secrets()->set('DEPLOY_KEY', $secret)->confirm();
 */
final readonly class Github
{
    public const string BASE_URL = 'https://api.github.com';

    public const string API_VERSION = '2022-11-28';

    public const string TOKEN = 'GITHUB_TOKEN';

    private function __construct(private Transport $transport) {}

    public static function make(#[\SensitiveParameter] Secret|string|null $token = null, ?ClientOptions $options = null, ?Credentials $credentials = null): self
    {
        return new self(new Transport(
            'GitHub',
            self::BASE_URL,
            new BearerToken(Credentials::resolve($token, self::TOKEN, $credentials)),
            $options ?? ClientOptions::defaults(),
            headers: ['Accept' => 'application/vnd.github+json', 'X-GitHub-Api-Version' => self::API_VERSION],
        ));
    }

    /** Who the token belongs to. */
    public function user(): Item
    {
        return Item::of($this->transport->get('/user')->json, ['login' => 'login', 'id' => 'id', 'name' => 'name', 'type' => 'type']);
    }

    /** Core REST quota: limit, remaining and when it resets. */
    public function rateLimit(): Item
    {
        return Item::of($this->transport->get('/rate_limit')->json, [
            'limit' => 'resources.core.limit', 'remaining' => 'resources.core.remaining', 'used' => 'resources.core.used',
            'resetAt' => static fn (array $r): string => gmdate('Y-m-d\TH:i:s\Z', Data::int($r, 'resources.core.reset')),
        ]);
    }

    /**
     * Repositories the token can see: the user's own, or an organisation's.
     *
     * @return list<Item>
     */
    public function repositories(?string $org = null, int $limit = 300): array
    {
        $path = $org === null ? '/user/repos' : '/orgs/'.Repository::parse($org.'/x')->owner.'/repos';
        $query = ['per_page' => 100] + ($org === null ? ['affiliation' => 'owner,collaborator,organization_member', 'sort' => 'pushed'] : ['sort' => 'pushed']);
        $repos = new Endpoint($this->transport, 'repository', $path, new GithubPaginator, self::REPO_FIELDS);

        return array_slice($repos->list($query), 0, max(1, $limit));
    }

    public function repo(string $repository): Repo
    {
        return new Repo($this->transport, Repository::parse($repository));
    }

    public const array REPO_FIELDS = [
        'fullName' => 'full_name', 'private' => 'private', 'visibility' => 'visibility', 'defaultBranch' => 'default_branch',
        'archived' => 'archived', 'pushedAt' => 'pushed_at',
    ];
}
