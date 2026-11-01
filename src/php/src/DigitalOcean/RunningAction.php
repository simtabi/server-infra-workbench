<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\DigitalOcean;

use Simtabi\ServerInfraWorkbench\DigitalOcean\Data\Action;
use Simtabi\ServerInfraWorkbench\DigitalOcean\Data\ActionStatus;
use Simtabi\ServerInfraWorkbench\Exception\ActionFailedException;
use Simtabi\ServerInfraWorkbench\Http\Sleeper;
use Simtabi\ServerInfraWorkbench\Http\Waiter;

/** A DigitalOcean action that has started. wait() polls until it completes, errors or times out. */
final readonly class RunningAction implements \JsonSerializable
{
    public function __construct(private Actions $actions, private Action $action, private Sleeper $sleeper) {}

    public function action(): Action
    {
        return $this->action;
    }

    public function wait(int $timeoutSeconds = 1800, int $pollSeconds = 10): Action
    {
        $final = Waiter::until(
            $this->sleeper,
            fn (): Action => $this->actions->find($this->action->id),
            static fn (Action $a): bool => $a->status->isFinished(),
            $timeoutSeconds,
            $pollSeconds,
            sprintf('DigitalOcean action %d (%s)', $this->action->id, $this->action->type),
        );
        if ($final->status === ActionStatus::Errored) {
            throw new ActionFailedException(sprintf('DigitalOcean action %d (%s) errored', $final->id, $final->type));
        }

        return $final;
    }

    /** @return array<string, mixed> */
    public function jsonSerialize(): array
    {
        return $this->action->jsonSerialize();
    }
}
