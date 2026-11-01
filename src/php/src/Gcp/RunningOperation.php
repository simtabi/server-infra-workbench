<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Gcp;

use Simtabi\ServerInfraWorkbench\Exception\ActionFailedException;
use Simtabi\ServerInfraWorkbench\Gcp\Data\Operation;
use Simtabi\ServerInfraWorkbench\Http\Sleeper;
use Simtabi\ServerInfraWorkbench\Http\Waiter;

final readonly class RunningOperation implements \JsonSerializable
{
    public function __construct(private Operations $operations, private Operation $operation, private Sleeper $sleeper) {}

    public function operation(): Operation
    {
        return $this->operation;
    }

    public function wait(int $timeoutSeconds = 1800, int $pollSeconds = 5): Operation
    {
        $final = Waiter::until(
            $this->sleeper,
            fn (): Operation => $this->operation->isDone() ? $this->operation : $this->operations->find($this->operation),
            static fn (Operation $op): bool => $op->isDone(),
            $timeoutSeconds,
            $pollSeconds,
            sprintf('Google Cloud operation %s (%s)', $this->operation->name, $this->operation->type),
        );
        if ($final->error !== null) {
            throw new ActionFailedException(sprintf('Google Cloud operation %s failed: %s', $final->name, $final->error));
        }

        return $final;
    }

    /** @return array<string, mixed> */
    public function jsonSerialize(): array
    {
        return $this->operation->jsonSerialize();
    }
}
