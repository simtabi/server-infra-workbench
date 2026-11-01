<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Exception;

use Simtabi\ServerInfraWorkbench\Support\Data;

/** The provider answered with an error. Subclasses narrow it by status; the message is already redacted. */
class ApiException extends \RuntimeException implements WorkbenchException
{
    final public function __construct(
        string $message,
        public readonly string $provider = '',
        public readonly int $status = 0,
        public readonly ?int $retryAfter = null,
    ) {
        parent::__construct($message, $status);
    }

    /** @param array<mixed> $body */
    public static function fromResponse(string $provider, string $method, string $uri, int $status, array $body, ?int $retryAfter = null): self
    {
        $detail = self::detail($body);
        $message = sprintf('%s %s %s failed: HTTP %d%s', $provider, $method, $uri, $status, $detail !== '' ? ' — '.$detail : '');

        $class = match (true) {
            $status === 401, $status === 403 => AuthenticationException::class,
            $status === 404 => NotFoundException::class,
            $status === 422, $status === 400 => ApiValidationException::class,
            $status === 429 => RateLimitException::class,
            default => self::class,
        };

        return new $class($message, $provider, $status, $retryAfter);
    }

    /**
     * Pulls the human message out of each provider's error envelope.
     *
     * @param array<mixed> $body
     */
    public static function detail(array $body): string
    {
        $parts = [];
        $errors = Data::get($body, 'errors');
        if (is_array($errors) && array_is_list($errors)) {             // Cloudflare
            foreach (Data::objects($body, 'errors') as $error) {
                $parts[] = trim(Data::string($error, 'code').' '.Data::string($error, 'message'));
            }
        }
        foreach (['message', 'error.message', 'error_description', 'id'] as $path) { // DO, Ploi, GCP, OAuth
            $value = Data::nullableString($body, $path);
            if ($value !== null && $value !== '' && $parts === []) {
                $parts[] = $value;
            }
        }
        foreach (Data::map($body, 'errors') as $field => $messages) { // Ploi/Laravel validation
            if (! is_numeric($field) && is_array($messages)) {
                $parts[] = $field.': '.implode(' ', array_filter($messages, is_string(...)));
            }
        }

        return substr(implode('; ', array_filter($parts, static fn (string $p): bool => $p !== '')), 0, 500);
    }
}
