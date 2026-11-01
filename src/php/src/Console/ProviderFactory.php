<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Console;

use Simtabi\ServerInfraWorkbench\Cloudflare\Cloudflare;
use Simtabi\ServerInfraWorkbench\DigitalOcean\DigitalOcean;
use Simtabi\ServerInfraWorkbench\Gcp\Auth\TokenProvider;
use Simtabi\ServerInfraWorkbench\Gcp\Gcp;
use Simtabi\ServerInfraWorkbench\Github\Github;
use Simtabi\ServerInfraWorkbench\Health\HealthCheck;
use Simtabi\ServerInfraWorkbench\Http\ClientOptions;
use Simtabi\ServerInfraWorkbench\Keys\AccountKeys;
use Simtabi\ServerInfraWorkbench\Keys\KeyProviders;
use Simtabi\ServerInfraWorkbench\Keys\ProcessSshRunner;
use Simtabi\ServerInfraWorkbench\Keys\ServerKeys;
use Simtabi\ServerInfraWorkbench\Keys\SshRunner;
use Simtabi\ServerInfraWorkbench\Ploi\Ploi;
use Simtabi\ServerInfraWorkbench\Security\Credentials;

/** Builds the provider clients for the CLI. Tests pass options with a mocked PSR-18 client. */
final readonly class ProviderFactory
{
    /** @param list<string>|null $localPublicKeys null reads ~/.ssh/*.pub (public halves only) */
    public function __construct(
        private ClientOptions $options,
        private Credentials $credentials,
        private ?TokenProvider $gcpTokens = null,
        private ?SshRunner $ssh = null,
        private ?array $localPublicKeys = null,
        private ?string $sshControlDir = null,
    ) {}

    public function withOptions(ClientOptions $options): self
    {
        return new self($options, $this->credentials, $this->gcpTokens, $this->ssh, $this->localPublicKeys, $this->sshControlDir);
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

    public function github(): Github
    {
        return Github::make(null, $this->options, $this->credentials);
    }

    public function gcp(?string $project): Gcp
    {
        return Gcp::make($project, $this->gcpTokens, $this->options, $this->credentials);
    }

    public function health(): HealthCheck
    {
        return new HealthCheck($this->options);
    }

    public function keyProviders(?string $config): KeyProviders
    {
        return KeyProviders::load($config);
    }

    public function accountKeys(string $provider, ?string $config): AccountKeys
    {
        return $this->keyProviders($config)->make($provider, $this->options, $this->credentials);
    }

    /** @param list<string> $sshOptions */
    public function serverKeys(string $host, array $sshOptions): ServerKeys
    {
        return new ServerKeys($this->ssh ?? new ProcessSshRunner, $host, $sshOptions, $this->options->auditLog(),
            $this->localPublicKeys ?? ServerKeys::localPublicKeys(), $this->sshControlDir);
    }
}
