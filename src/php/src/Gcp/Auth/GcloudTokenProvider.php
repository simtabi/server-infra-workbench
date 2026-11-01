<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Gcp\Auth;

use Simtabi\ServerInfraWorkbench\Exception\CredentialException;
use Simtabi\ServerInfraWorkbench\Security\Secret;

/**
 * Wraps `gcloud auth print-access-token` for people who log in with gcloud instead of a key file.
 * Runs gcloud without a shell; the token is cached for 30 minutes (gcloud tokens last ~60).
 */
final class GcloudTokenProvider implements TokenProvider
{
    private ?Secret $token = null;

    private int $expires = 0;

    public function __construct(private readonly string $binary = 'gcloud') {}

    public static function available(string $binary = 'gcloud'): bool
    {
        foreach (explode(PATH_SEPARATOR, (string) getenv('PATH')) as $dir) {
            if ($dir !== '' && is_executable($dir.DIRECTORY_SEPARATOR.$binary)) {
                return true;
            }
        }

        return false;
    }

    public function token(string $scope): Secret
    {
        if ($this->token !== null && time() < $this->expires) {
            return $this->token;
        }
        $process = proc_open([$this->binary, 'auth', 'print-access-token'], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        if (! is_resource($process)) {
            throw new CredentialException('could not run gcloud; install the Google Cloud CLI or set GOOGLE_APPLICATION_CREDENTIALS');
        }
        $out = trim((string) stream_get_contents($pipes[1]));
        $err = trim((string) stream_get_contents($pipes[2]));
        fclose($pipes[1]);
        fclose($pipes[2]);
        if (proc_close($process) !== 0 || $out === '') {
            throw new CredentialException('gcloud auth print-access-token failed'.($err !== '' ? ': '.strtok($err, "\n") : '').' — run `gcloud auth login` on its own first');
        }
        $this->token = new Secret($out);
        $this->expires = time() + 1800;

        return $this->token;
    }

    public function secrets(): array
    {
        return $this->token !== null ? [$this->token->reveal()] : [];
    }
}
