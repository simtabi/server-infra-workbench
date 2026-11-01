<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Cloudflare;

use Simtabi\ServerInfraWorkbench\Cloudflare\Data\Zone;
use Simtabi\ServerInfraWorkbench\Exception\ActionFailedException;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Endpoint;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Security\IssuedCredential;
use Simtabi\ServerInfraWorkbench\Security\Secret;
use Simtabi\ServerInfraWorkbench\Support\Item;
use Simtabi\ServerInfraWorkbench\Support\Validate;

/**
 * Cloudflare Origin CA certificates: free, long-lived certificates that only Cloudflare's edge trusts,
 * which is exactly what "Full (strict)" needs. The private key is generated HERE (EC P-256) and only the
 * CSR is sent, so Cloudflare never sees the key. The key comes back as a Secret, written to a 0600 file.
 */
final readonly class OriginCertificates
{
    public const array VALIDITY = [7, 30, 90, 365, 730, 1095, 5475];

    private Endpoint $api;

    public function __construct(Transport $transport, private Zone $zone)
    {
        $this->api = new Endpoint($transport, 'origin certificate', '/certificates', new CloudflarePaginator, [
            'id' => 'id', 'hostnames' => 'hostnames', 'expiresOn' => 'expires_on', 'requestType' => 'request_type', 'validityDays' => 'requested_validity',
        ], CloudflarePaginator::result(...), ['zone_id' => $zone->id]);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->api->list(['zone_id' => $this->zone->id]);
    }

    /**
     * @param list<string> $hostnames e.g. ["example.com", "*.example.com"]; all inside the zone
     * @return PendingAction<IssuedCredential> the item is the certificate (PEM, public), the one-time value is its private key
     */
    public function create(array $hostnames, int $validityDays = 5475): PendingAction
    {
        if ($hostnames === []) {
            $hostnames = [$this->zone->name, '*.'.$this->zone->name];
        }
        foreach ($hostnames as $host) {
            $bare = str_starts_with($host, '*.') ? substr($host, 2) : $host;
            Validate::domain($bare, 'hostname');
            if ($bare !== $this->zone->name && ! str_ends_with($bare, '.'.$this->zone->name)) {
                throw new ValidationException(sprintf('hostname "%s" is not inside the zone %s', $host, $this->zone->name));
            }
        }
        if (! in_array($validityDays, self::VALIDITY, true)) {
            throw new ValidationException('validity (days) must be one of '.implode(', ', self::VALIDITY));
        }
        $transport = $this->api->transport();
        $plan = ['hostnames' => $hostnames, 'requested_validity' => $validityDays, 'request_type' => 'origin-ecc', 'csr' => '(generated locally at confirm)'];

        return $transport->pending('create origin certificate', implode(', ', $hostnames)." ({$validityDays} days)", 'POST', '/certificates', $plan,
            function () use ($transport, $hostnames, $validityDays): IssuedCredential {
                [$key, $csr] = self::keyAndCsr($hostnames[0]);
                $row = CloudflarePaginator::result($transport->send('POST', '/certificates', [], [
                    'hostnames' => $hostnames, 'requested_validity' => $validityDays, 'request_type' => 'origin-ecc', 'csr' => $csr,
                ])->json);

                return new IssuedCredential(Item::of($row, ['id' => 'id', 'hostnames' => 'hostnames', 'expiresOn' => 'expires_on', 'certificate' => 'certificate']), $key);
            }, note: 'the private key is generated locally and written to the --out file (chmod 600); install both on the origin, then set ssl strict');
    }

    /**
     * Destructive: the origin keeps serving the certificate, and Cloudflare stops trusting it (526 errors).
     *
     * @return PendingAction<bool>
     */
    public function revoke(string $id): PendingAction
    {
        return $this->api->delete(Validate::segment($id, 'certificate id', 64), note: 'origins still using it start failing with 526 under Full (strict)');
    }

    /** @return array{0: Secret, 1: string} private key PEM (secret), CSR PEM */
    public static function keyAndCsr(string $commonName): array
    {
        if (! function_exists('openssl_pkey_new')) {
            throw new ActionFailedException('the openssl PHP extension is required to generate the origin certificate key');
        }
        $key = openssl_pkey_new(['private_key_type' => OPENSSL_KEYTYPE_EC, 'curve_name' => 'prime256v1']);
        if ($key === false) {
            throw new ActionFailedException('could not generate an EC key: '.self::opensslError());
        }
        $dn = ['commonName' => $commonName];
        $signing = $key; // openssl_csr_new takes the key by reference
        $csr = openssl_csr_new($dn, $signing, ['digest_alg' => 'sha256']);
        $csrPem = '';
        $keyPem = '';
        if (! $csr instanceof \OpenSSLCertificateSigningRequest || ! openssl_csr_export($csr, $csrPem) || ! openssl_pkey_export($key, $keyPem)) {
            throw new ActionFailedException('could not build the CSR: '.self::opensslError());
        }
        if (! is_string($keyPem) || ! is_string($csrPem)) {
            throw new ActionFailedException('openssl returned no PEM output');
        }

        return [new Secret($keyPem), $csrPem];
    }

    private static function opensslError(): string
    {
        $error = openssl_error_string();

        return $error === false ? 'unknown openssl error' : $error;
    }
}
