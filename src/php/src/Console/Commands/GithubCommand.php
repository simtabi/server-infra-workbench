<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Console\Commands;

use Simtabi\ServerInfraWorkbench\Console\Input;
use Simtabi\ServerInfraWorkbench\Console\ProviderFactory;
use Simtabi\ServerInfraWorkbench\Console\Runner;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Github\Github;
use Simtabi\ServerInfraWorkbench\Github\Repo;
use Simtabi\ServerInfraWorkbench\Support\Item;

/** `workbench github ...` (alias gh): GitHub REST API 2022-11-28. */
final readonly class GithubCommand implements Command
{
    public function __construct(private ProviderFactory $providers, private Runner $r) {}

    public function run(Input $in): int
    {
        $r = $this->r;
        $gh = fn (): Github => $this->providers->github();
        $repo = fn (): Repo => $gh()->repo($in->required('repo', 'owner/name'));

        return match ($in->optionalArg(0)) {
            'whoami' => $r->showOne($in, $gh()->user()),
            'rate-limit' => $r->showOne($in, $gh()->rateLimit()),
            'repos' => $r->show($in, $gh()->repositories($in->value('org'), $in->int('limit', 100)), ['fullName' => 'REPOSITORY', 'visibility' => 'VISIBILITY', 'defaultBranch' => 'BRANCH', 'archived' => 'ARCHIVED', 'pushedAt' => 'PUSHED']),
            'repo' => $r->showOne($in, $repo()->get()),
            'workflows' => $r->show($in, $repo()->workflows()->list(), ['id' => 'ID', 'name' => 'NAME', 'path' => 'PATH', 'state' => 'STATE']),
            'runs' => $r->show($in, $repo()->workflows()->runs($in->value('workflow'), $in->value('branch'), $in->value('status'), $in->int('limit', 20)),
                ['id' => 'ID', 'workflow' => 'WORKFLOW', 'branch' => 'BRANCH', 'event' => 'EVENT', 'status' => 'STATUS', 'conclusion' => 'RESULT', 'createdAt' => 'CREATED']),
            'run' => $in->flag('wait')
                ? $r->showOne($in, $repo()->workflows()->wait($in->arg(1, 'run-id'), $in->int('timeout', 3600)), 'run finished')
                : $r->showOne($in, $repo()->workflows()->run($in->arg(1, 'run-id'))),
            'dispatch' => $r->write($in, $repo()->workflows()->dispatch($in->arg(1, 'workflow'), $in->required('ref', 'branch or tag'), self::inputs($in->list('inputs'))),
                fn (bool $ok): int => $r->done($in, $ok, 'workflow dispatched (see: workbench github runs --repo '.$in->required('repo').' --workflow '.$in->arg(1, 'workflow').')')),
            'rerun' => $r->write($in, $repo()->workflows()->rerunFailed($in->arg(1, 'run-id')), fn (bool $ok): int => $r->done($in, $ok, 'failed jobs re-queued')),
            'cancel' => $r->write($in, $repo()->workflows()->cancel($in->arg(1, 'run-id')), fn (bool $ok): int => $r->done($in, $ok, 'cancellation requested')),
            'secrets' => match ($in->optionalArg(1)) {
                'list', null => $r->show($in, $repo()->secrets($in->value('env'))->list(), ['name' => 'NAME', 'createdAt' => 'CREATED', 'updatedAt' => 'UPDATED']),
                'set' => $r->write($in, $repo()->secrets($in->value('env'))->set($in->arg(2, 'name'), $r->readSecret($in)), fn (bool $ok): int => $r->done($in, $ok, 'secret saved (encrypted locally; the value was never printed)')),
                'delete' => $r->write($in, $repo()->secrets($in->value('env'))->delete($in->arg(2, 'name')), fn (bool $ok): int => $r->done($in, $ok, 'secret deleted')),
                default => $r->usage('github'),
            },
            'deploy-keys' => match ($in->optionalArg(1)) {
                'list', null => $r->show($in, $repo()->deployKeys()->list(), ['id' => 'ID', 'title' => 'TITLE', 'readOnly' => 'READ-ONLY', 'lastUsed' => 'LAST USED']),
                'add' => $r->write($in, $repo()->deployKeys()->add($in->required('title'), $r->readFile($in->required('key-file', 'the .pub file')) ?? '', ! $in->flag('write')),
                    fn (Item $k): int => $r->showOne($in, $k, 'deploy key added')),
                'delete' => $r->write($in, $repo()->deployKeys()->delete($in->arg(2, 'key-id')), fn (bool $ok): int => $r->done($in, $ok, 'deploy key deleted')),
                default => $r->usage('github'),
            },
            'releases' => match ($in->optionalArg(1)) {
                'list', null => $r->show($in, $repo()->releases()->list($in->int('limit', 30)), ['id' => 'ID', 'tag' => 'TAG', 'name' => 'NAME', 'draft' => 'DRAFT', 'prerelease' => 'PRE', 'publishedAt' => 'PUBLISHED']),
                'latest' => $r->showOne($in, $repo()->releases()->latest()),
                'create' => $r->write($in, $repo()->releases()->create($in->arg(2, 'tag'), $in->value('target'), $in->value('title'), $r->readFile($in->value('notes-file')), $in->flag('draft'), $in->flag('prerelease')),
                    fn (Item $rel): int => $r->showOne($in, $rel, 'release created')),
                'delete' => $r->write($in, $repo()->releases()->delete($in->arg(2, 'release-id')), fn (bool $ok): int => $r->done($in, $ok, 'release deleted')),
                default => $r->usage('github'),
            },
            null, 'help' => $r->usage('github'),
            default => throw new ValidationException(sprintf('unknown "github %s" (see: workbench github --help)', $in->arg(0, 'command'))),
        };
    }

    /**
     * --inputs key=value,key=value
     *
     * @param list<string> $pairs
     * @return array<string, string>
     */
    private static function inputs(array $pairs): array
    {
        $out = [];
        foreach ($pairs as $pair) {
            [$key, $value] = array_pad(explode('=', $pair, 2), 2, null);
            if ($value === null) {
                throw new ValidationException(sprintf('--inputs takes name=value pairs ("%s" has no =)', $pair));
            }
            $out[$key] = $value;
        }

        return $out;
    }
}
