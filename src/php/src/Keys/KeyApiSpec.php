<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Keys;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;

/**
 * Describes one provider's SSH-key REST API. The built-in providers and the ones from a keys.json
 * "extra_providers" list use the same description (same field names as the old vpskeys config).
 */
final readonly class KeyApiSpec
{
    public const array PAGINATION = ['none', 'digitalocean', 'cursor', 'hetzner', 'linode', 'scaleway'];

    /** @param array<string, string> $extraHeaders */
    public function __construct(
        public string $name,
        public string $baseUrl,
        public string $tokenEnv,
        public string $listPath,
        public string $listField,
        public string $idField = 'id',
        public string $nameField = 'name',
        public string $publicKeyField = 'public_key',
        public string $fingerprintField = '',
        public string $itemField = '',
        public string $createPath = '',
        public string $createNameField = 'name',
        public string $createKeyField = 'public_key',
        public string $deletePath = '',
        public string $renamePath = '',
        public string $renameMethod = 'PUT',
        public string $renameField = 'name',
        public string $authHeaderName = 'Authorization',
        public string $authHeaderPrefix = 'Bearer ',
        public array $extraHeaders = [],
        public string $pagination = 'none',
        public int $pageSize = 100,
        public string $scopeEnv = '',
        public string $scopeField = '',
    ) {
        if (preg_match('/^[a-z][a-z0-9-]{0,31}$/', $name) !== 1) {
            throw new ValidationException(sprintf('provider name "%s" must be lower-case letters, digits and dashes', $name));
        }
        if (! str_starts_with($baseUrl, 'https://') || parse_url($baseUrl, PHP_URL_HOST) === null) {
            throw new ValidationException(sprintf('%s: base_url must be an https:// URL', $name));
        }
        if (preg_match('/^[A-Z][A-Z0-9_]*$/', $tokenEnv) !== 1) {
            throw new ValidationException(sprintf('%s: token_env must be an UPPER_CASE variable name', $name));
        }
        if (! in_array($pagination, self::PAGINATION, true)) {
            throw new ValidationException(sprintf('%s: pagination must be one of %s', $name, implode(', ', self::PAGINATION)));
        }
        if (! in_array(strtoupper($renameMethod), ['PUT', 'PATCH', 'POST'], true)) {
            throw new ValidationException(sprintf('%s: rename_method must be PUT, PATCH or POST', $name));
        }
        if (preg_match('/^[A-Za-z][A-Za-z0-9-]*$/', $authHeaderName) !== 1) {
            throw new ValidationException(sprintf('%s: auth_header_name is not a valid header name', $name));
        }
    }

    /**
     * From one "extra_providers" entry. Required: name, base_url, token_env, list_path, list_field.
     *
     * @param array<mixed> $entry
     */
    public static function fromConfig(array $entry): self
    {
        $known = ['name', 'base_url', 'token_env', 'list_path', 'list_field', 'id_field', 'name_field', 'public_key_field', 'fingerprint_field', 'item_field',
            'create_path', 'create_name_field', 'create_key_field', 'delete_path', 'rename_path', 'rename_method', 'rename_field',
            'auth_header_name', 'auth_header_prefix', 'extra_headers', 'pagination', 'page_size'];
        $unknown = array_diff(array_map(strval(...), array_keys($entry)), $known);
        if ($unknown !== []) {
            throw new ValidationException('bad extra_providers entry: unknown field(s) '.implode(', ', $unknown));
        }
        foreach (['name', 'base_url', 'token_env', 'list_path', 'list_field'] as $required) {
            if (! isset($entry[$required]) || ! is_string($entry[$required])) {
                throw new ValidationException("bad extra_providers entry: \"{$required}\" is required");
            }
        }
        $str = static fn (string $k, string $d = ''): string => is_string($entry[$k] ?? null) ? $entry[$k] : $d;
        $headers = [];
        foreach (is_array($entry['extra_headers'] ?? null) ? $entry['extra_headers'] : [] as $k => $v) {
            if (is_string($k) && is_string($v)) {
                $headers[$k] = $v;
            }
        }

        return new self(
            $str('name'), $str('base_url'), $str('token_env'), $str('list_path'), $str('list_field'),
            $str('id_field', 'id'), $str('name_field', 'name'), $str('public_key_field', 'public_key'), $str('fingerprint_field'), $str('item_field'),
            $str('create_path'), $str('create_name_field', 'name'), $str('create_key_field', 'public_key'),
            $str('delete_path'), $str('rename_path'), $str('rename_method', 'PUT'), $str('rename_field', 'name'),
            $str('auth_header_name', 'Authorization'), array_key_exists('auth_header_prefix', $entry) ? $str('auth_header_prefix') : 'Bearer ',
            $headers, $str('pagination', 'none'), is_int($entry['page_size'] ?? null) ? $entry['page_size'] : 100,
        );
    }
}
