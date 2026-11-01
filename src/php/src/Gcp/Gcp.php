<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Gcp;

use Simtabi\ServerInfraWorkbench\Exception\CredentialException;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Gcp\Auth\GcloudTokenProvider;
use Simtabi\ServerInfraWorkbench\Gcp\Auth\GoogleOAuth;
use Simtabi\ServerInfraWorkbench\Gcp\Auth\ServiceAccountTokenProvider;
use Simtabi\ServerInfraWorkbench\Gcp\Auth\TokenProvider;
use Simtabi\ServerInfraWorkbench\Http\ClientOptions;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Security\Credentials;

/**
 * Google Cloud: Compute Engine v1 (instances, snapshots, firewalls), Cloud DNS v1 and Cloud Storage JSON v1.
 * Each API has its own transport and OAuth scopes (read-only for reads).
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

    public const string DNS_URL = 'https://dns.googleapis.com/dns/v1';

    public const string STORAGE_URL = 'https://storage.googleapis.com/storage/v1';

    public const string KEY_FILE = 'GOOGLE_APPLICATION_CREDENTIALS';

    public const string PROJECT = 'GCP_PROJECT';

    private function __construct(private Transport $transport, private string $project, private Transport $dns, private Transport $storage) {}

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

        return new self(
            new Transport('Google Cloud', self::BASE_URL, GoogleOAuth::compute($tokens), $options),
            self::validProject($project),
            new Transport('Google Cloud DNS', self::DNS_URL, GoogleOAuth::dns($tokens), $options),
            new Transport('Google Cloud Storage', self::STORAGE_URL, GoogleOAuth::storage($tokens), $options),
        );
    }

    public function project(): string
    {
        return $this->project;
    }

    public function instances(): Instances
    {
        return new Instances($this->transport, $this->project, $this->operations());
    }

    public function snapshots(): Snapshots
    {
        return new Snapshots($this->transport, $this->project, $this->operations());
    }

    public function firewalls(): Firewalls
    {
        return new Firewalls($this->transport, $this->project, $this->operations());
    }

    public function dns(): CloudDns
    {
        return new CloudDns($this->dns, $this->project);
    }

    public function storage(): Storage
    {
        return new Storage($this->storage, $this->project);
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
