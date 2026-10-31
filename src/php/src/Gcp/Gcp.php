<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp;

use Simtabi\VpsServerWorkbench\Exception\CredentialException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Gcp\Auth\GcloudTokenProvider;
use Simtabi\VpsServerWorkbench\Gcp\Auth\GoogleOAuth;
use Simtabi\VpsServerWorkbench\Gcp\Auth\ServiceAccountTokenProvider;
use Simtabi\VpsServerWorkbench\Gcp\Auth\TokenProvider;
use Simtabi\VpsServerWorkbench\Http\ClientOptions;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Security\Credentials;

/**
 * Google Compute Engine v1, deliberately minimal: instances, snapshots, firewalls.
 *
 * Auth, in order: an explicit TokenProvider; $GOOGLE_APPLICATION_CREDENTIALS (service-account JSON,
 * chmod 600, outside any repo); otherwise `gcloud auth print-access-token`.
 *
 *     Gcp::make('my-project')->instances()->list();
 *     Gcp::make()->snapshots()->create('us-east1-b', 'db-disk', 'pre-upgrade')->confirm()->wait();
 */
final readonly class Gcp
{
    public const string BASE_URL = 'https://compute.googleapis.com/compute/v1';

    public const string KEY_FILE = 'GOOGLE_APPLICATION_CREDENTIALS';

    public const string PROJECT = 'GCP_PROJECT';

    private function __construct(private Transport $transport, private string $project) {}

    public static function make(?string $project = null, ?TokenProvider $tokens = null, ?ClientOptions $options = null, ?Credentials $credentials = null): self
    {
        $options ??= ClientOptions::defaults();
        $credentials ??= Credentials::fromEnvironment();

        if ($tokens === null) {
            if ($credentials->has(self::KEY_FILE)) {
                $tokens = ServiceAccountTokenProvider::fromFile($credentials->get(self::KEY_FILE)->reveal(), $options);
            } elseif (GcloudTokenProvider::available()) {
                $tokens = new GcloudTokenProvider;
            } else {
                throw new CredentialException(sprintf('no Google credentials: set %s to a service-account key, or install gcloud and run `gcloud auth login`', self::KEY_FILE));
            }
        }

        $project ??= $credentials->has(self::PROJECT) ? $credentials->get(self::PROJECT)->reveal() : null;
        $project ??= $tokens instanceof ServiceAccountTokenProvider ? $tokens->projectId() : null;
        if ($project === null) {
            throw new CredentialException(sprintf('no Google Cloud project: pass one or set %s', self::PROJECT));
        }

        return new self(new Transport('Google Cloud', self::BASE_URL, new GoogleOAuth($tokens), $options), self::validProject($project));
    }

    public function project(): string
    {
        return $this->project;
    }

    public function instances(): Instances
    {
        return new Instances($this->transport, $this->project);
    }

    public function snapshots(): Snapshots
    {
        return new Snapshots($this->transport, $this->project, $this->operations());
    }

    public function firewalls(): Firewalls
    {
        return new Firewalls($this->transport, $this->project);
    }

    public function operations(): Operations
    {
        return new Operations($this->transport, $this->project);
    }

    private static function validProject(string $project): string
    {
        if (preg_match('/^(?:[a-z][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]$/', $project) !== 1) {
            throw new ValidationException(sprintf('"%s" is not a valid Google Cloud project id', $project));
        }

        return $project;
    }
}
