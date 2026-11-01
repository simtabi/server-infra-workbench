<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Github;

use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Support\Item;

/** One repository and its sub-resources. */
final readonly class Repo
{
    public function __construct(private Transport $transport, private Repository $repository) {}

    public function repository(): Repository
    {
        return $this->repository;
    }

    public function get(): Item
    {
        return Item::of($this->transport->get($this->repository->path())->json, Github::REPO_FIELDS);
    }

    public function workflows(): Workflows
    {
        return new Workflows($this->transport, $this->repository);
    }

    /** Actions secrets of the repository, or of one of its environments. */
    public function secrets(?string $environment = null): Secrets
    {
        return new Secrets($this->transport, $this->repository, $environment);
    }

    public function deployKeys(): DeployKeys
    {
        return new DeployKeys($this->transport, $this->repository);
    }

    public function releases(): Releases
    {
        return new Releases($this->transport, $this->repository);
    }
}
