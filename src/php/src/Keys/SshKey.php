<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Keys;

use Simtabi\ServerInfraWorkbench\Support\ExportsProperties;

/** An account (dashboard) SSH key as a provider reports it. Fingerprint and key may be empty. */
final readonly class SshKey implements \JsonSerializable
{
    use ExportsProperties;

    public function __construct(
        public string $provider,
        public string $id,
        public string $name,
        public string $publicKey,
        public string $fingerprint,
    ) {}

    /** Provider fingerprint, else one computed from the key (SHA256), else empty. */
    public function displayFingerprint(): string
    {
        if ($this->fingerprint !== '') {
            return $this->fingerprint;
        }

        return PublicKey::tryParse($this->publicKey)?->fingerprint() ?? '';
    }
}
