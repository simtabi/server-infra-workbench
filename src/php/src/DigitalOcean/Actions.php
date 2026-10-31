<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Action;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Validate;

final readonly class Actions
{
    public function __construct(private Transport $transport) {}

    public function find(int|string $id): Action
    {
        return Action::fromArray(Data::map($this->transport->get('/v2/actions/'.Validate::id($id, 'action id'))->json, 'action'));
    }

    public function track(Action $action): RunningAction
    {
        return new RunningAction($this, $action, $this->transport->options()->sleeper());
    }
}
