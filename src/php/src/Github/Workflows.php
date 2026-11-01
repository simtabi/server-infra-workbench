<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Github;

use Simtabi\ServerInfraWorkbench\Exception\ActionFailedException;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Endpoint;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Http\Waiter;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Item;
use Simtabi\ServerInfraWorkbench\Support\Validate;

/** GitHub Actions: workflows and their runs. */
final readonly class Workflows
{
    public const array STATUSES = ['queued', 'in_progress', 'completed', 'success', 'failure', 'cancelled', 'action_required', 'waiting', 'pending'];

    private const array RUN_FIELDS = [
        'id' => 'id', 'workflow' => 'name', 'title' => 'display_title', 'branch' => 'head_branch', 'sha' => 'head_sha', 'event' => 'event',
        'status' => 'status', 'conclusion' => 'conclusion', 'attempt' => 'run_attempt', 'url' => 'html_url', 'createdAt' => 'created_at',
    ];

    private Endpoint $workflows;

    private Endpoint $runs;

    public function __construct(private Transport $transport, private Repository $repo)
    {
        $this->workflows = new Endpoint($transport, 'workflow', $repo->path('actions', 'workflows'), new GithubPaginator('workflows'),
            ['id' => 'id', 'name' => 'name', 'path' => 'path', 'state' => 'state'], null, ['per_page' => 100]);
        $this->runs = new Endpoint($transport, 'workflow run', $repo->path('actions', 'runs'), new GithubPaginator('workflow_runs'), self::RUN_FIELDS);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->workflows->list();
    }

    /**
     * Newest first; optionally one workflow, branch or status.
     *
     * @return list<Item>
     */
    public function runs(?string $workflow = null, ?string $branch = null, ?string $status = null, int $limit = 20): array
    {
        $limit = Validate::range($limit, 1, 1000, 'limit');
        $query = ['per_page' => min(100, $limit)];
        if ($branch !== null) {
            $query['branch'] = self::ref($branch);
        }
        if ($status !== null) {
            $query['status'] = in_array($status, self::STATUSES, true) ? $status : throw new ValidationException('status must be one of '.implode(', ', self::STATUSES));
        }
        $endpoint = $workflow === null ? $this->runs
            : new Endpoint($this->transport, 'workflow run', $this->repo->path('actions', 'workflows', self::workflow($workflow), 'runs'), new GithubPaginator('workflow_runs'), self::RUN_FIELDS);
        $out = [];
        foreach ($this->transport->paginate($endpoint->path(), $query, new GithubPaginator('workflow_runs'), (int) ceil($limit / 100)) as $row) {
            $out[] = $endpoint->item($row);
            if (count($out) >= $limit) {
                break;
            }
        }

        return $out;
    }

    public function run(int|string $id): Item
    {
        return $this->runs->get(Validate::id($id, 'run id'));
    }

    /**
     * Trigger a workflow that has `on: workflow_dispatch`. GitHub answers 204 with no run id; find the
     * run afterwards with runs(workflow, branch).
     *
     * @param array<string, string> $inputs
     * @return PendingAction<bool>
     */
    public function dispatch(string $workflow, string $ref, array $inputs = []): PendingAction
    {
        $workflow = self::workflow($workflow);
        if (count($inputs) > 25) {
            throw new ValidationException('GitHub accepts at most 25 workflow inputs');
        }
        foreach ($inputs as $name => $value) {
            if (preg_match('/^[A-Za-z_][A-Za-z0-9_-]{0,99}$/', (string) $name) !== 1 || preg_match('/[\x00-\x08\x0b-\x1f\x7f]/', $value) === 1) {
                throw new ValidationException(sprintf('workflow input "%s" is not a valid name=value', $name));
            }
        }
        $path = $this->repo->path('actions', 'workflows', $workflow, 'dispatches');
        $body = ['ref' => self::ref($ref)] + ($inputs === [] ? [] : ['inputs' => $inputs]);

        return $this->transport->pending('dispatch workflow', "{$workflow} on {$ref} in {$this->repo}", 'POST', $path, $body,
            fn (): bool => $this->transport->send('POST', $path, [], $body)->status < 300, note: 'runs with the workflow\'s own permissions and secrets');
    }

    /** @return PendingAction<bool> */
    public function rerunFailed(int|string $runId): PendingAction
    {
        return $this->runAction($runId, 'rerun-failed-jobs', 're-run failed jobs', null);
    }

    /** @return PendingAction<bool> */
    public function cancel(int|string $runId): PendingAction
    {
        return $this->runAction($runId, 'cancel', 'cancel run', 'a deploy cancelled half-way can leave the target half-updated');
    }

    /** Poll until the run completes; throws when it did not succeed. */
    public function wait(int|string $runId, int $timeoutSeconds = 3600, int $pollSeconds = 15): Item
    {
        $id = Validate::id($runId, 'run id');
        $run = Waiter::until($this->transport->options()->sleeper(), fn (): Item => $this->run($id),
            static fn (Item $r): bool => $r->string('status') === 'completed', $timeoutSeconds, $pollSeconds, "GitHub run {$id} in {$this->repo}");
        if (! in_array($run->string('conclusion'), ['success', 'skipped', 'neutral'], true)) {
            throw new ActionFailedException(sprintf('GitHub run %d finished with %s: %s', $id, $run->string('conclusion'), $run->string('url')));
        }

        return $run;
    }

    /** @return PendingAction<bool> */
    private function runAction(int|string $runId, string $verb, string $action, ?string $note): PendingAction
    {
        $id = Validate::id($runId, 'run id');
        $path = $this->runs->path($id, $verb);

        return $this->transport->pending($action, "{$id} in {$this->repo}", 'POST', $path, [],
            fn (): bool => $this->transport->send('POST', $path)->status < 300, note: $note);
    }

    /** A workflow id or its file name (deploy.yml). */
    public static function workflow(string $workflow): string
    {
        if (preg_match('/^(\d{1,20}|[A-Za-z0-9_.-]{1,200}\.ya?ml)$/', $workflow) !== 1) {
            throw new ValidationException(sprintf('workflow "%s" must be its numeric id or file name (deploy.yml)', substr($workflow, 0, 80)));
        }

        return $workflow;
    }

    public static function ref(string $ref): string
    {
        if (preg_match('#^[A-Za-z0-9._/-]{1,250}$#', $ref) !== 1 || str_contains($ref, '..') || str_starts_with($ref, '/') || str_ends_with($ref, '/')) {
            throw new ValidationException(sprintf('"%s" is not a branch, tag or ref', substr($ref, 0, 80)));
        }

        return $ref;
    }
}
