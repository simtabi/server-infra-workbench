<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console;

use Simtabi\VpsServerWorkbench\Cloudflare\Cloudflare;
use Simtabi\VpsServerWorkbench\DigitalOcean\DigitalOcean;
use Simtabi\VpsServerWorkbench\Gcp\Auth\TokenProvider;
use Simtabi\VpsServerWorkbench\Gcp\Gcp;
use Simtabi\VpsServerWorkbench\Http\ClientOptions;
use Simtabi\VpsServerWorkbench\Ploi\Ploi;
use Simtabi\VpsServerWorkbench\Security\Credentials;

/** Builds the provider clients for the CLI. Tests pass options with a mocked PSR-18 client. */
final readonly class ProviderFactory
{
    public function __construct(private ClientOptions $options, private Credentials $credentials, private ?TokenProvider $gcpTokens = null) {}

    public function withOptions(ClientOptions $options): self
    {
        return new self($options, $this->credentials, $this->gcpTokens);
    }

    public function options(): ClientOptions
    {
        return $this->options;
    }

    public function credentials(): Credentials
    {
        return $this->credentials;
    }

    public function digitalOcean(): DigitalOcean
    {
        return DigitalOcean::make(null, $this->options, $this->credentials);
    }

    public function cloudflare(): Cloudflare
    {
        return Cloudflare::make(null, $this->options, $this->credentials);
    }

    public function ploi(): Ploi
    {
        return Ploi::make(null, $this->options, $this->credentials);
    }

    public function gcp(?string $project): Gcp
    {
        return Gcp::make($project, $this->gcpTokens, $this->options, $this->credentials);
    }
}
