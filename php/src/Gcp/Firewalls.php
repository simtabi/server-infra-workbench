<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp;

use Simtabi\VpsServerWorkbench\Gcp\Data\Firewall;
use Simtabi\VpsServerWorkbench\Http\Transport;

final readonly class Firewalls
{
    public function __construct(private Transport $transport, private string $project) {}

    /** @return list<Firewall> */
    public function list(): array
    {
        $out = [];
        foreach ($this->transport->paginate("/projects/{$this->project}/global/firewalls", ['maxResults' => 500], new GcpPaginator) as $row) {
            $out[] = Firewall::fromArray($row);
        }

        return $out;
    }
}
