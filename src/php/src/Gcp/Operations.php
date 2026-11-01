<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Gcp;

use Simtabi\ServerInfraWorkbench\Gcp\Data\Operation;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Validate;

final readonly class Operations
{
    public function __construct(private Transport $transport, private string $project) {}

    public function find(Operation $operation): Operation
    {
        $scope = $operation->zone !== null ? 'zones/'.Validate::gcpName($operation->zone, 'zone') : 'global';
        $name = Validate::token($operation->name, 'operation');

        return Operation::fromArray(Data::map(['op' => $this->transport->get("/projects/{$this->project}/{$scope}/operations/{$name}")->json], 'op'));
    }

    public function track(Operation $operation): RunningOperation
    {
        return new RunningOperation($this, $operation, $this->transport->options()->sleeper());
    }
}
