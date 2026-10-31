<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp;

use Simtabi\VpsServerWorkbench\Gcp\Data\Operation;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Validate;

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
