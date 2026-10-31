<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Http;

use Psr\Http\Message\ResponseInterface;

final readonly class ApiResponse
{
    /** @param array<mixed> $json */
    public function __construct(public int $status, public array $json, public string $body, public ResponseInterface $raw) {}

    public static function from(ResponseInterface $response): self
    {
        $body = (string) $response->getBody();
        $json = [];
        if ($body !== '') {
            try {
                $decoded = json_decode($body, true, 512, JSON_THROW_ON_ERROR);
                $json = is_array($decoded) ? $decoded : [];
            } catch (\JsonException) {
                $json = [];
            }
        }

        return new self($response->getStatusCode(), $json, $body, $response);
    }

    public function header(string $name): ?string
    {
        $value = $this->raw->getHeaderLine($name);

        return $value === '' ? null : $value;
    }
}
