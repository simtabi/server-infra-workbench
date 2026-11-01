<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\DigitalOcean;

use Simtabi\ServerInfraWorkbench\DigitalOcean\Data\Action;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Validate;

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
