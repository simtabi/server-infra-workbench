<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Ploi;

use Simtabi\VpsServerWorkbench\Http\BearerToken;
use Simtabi\VpsServerWorkbench\Http\ClientOptions;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Security\Credentials;
use Simtabi\VpsServerWorkbench\Security\Secret;

/**
 * Ploi API.
 *
 *     Ploi::make($token)->servers()->find($id)->sites()->list();
 *     Ploi::make()->servers()->find(12)->sites()->deploy(34)->confirm();
 */
final readonly class Ploi
{
    public const string BASE_URL = 'https://ploi.io/api';

    public const string TOKEN = 'PLOI_API_TOKEN';

    private function __construct(private Transport $transport) {}

    public static function make(#[\SensitiveParameter] Secret|string|null $token = null, ?ClientOptions $options = null, ?Credentials $credentials = null): self
    {
        return new self(new Transport(
            'Ploi',
            self::BASE_URL,
            new BearerToken(Credentials::resolve($token, self::TOKEN, $credentials)),
            $options ?? ClientOptions::defaults(),
        ));
    }

    public function servers(): Servers
    {
        return new Servers($this->transport);
    }
}
