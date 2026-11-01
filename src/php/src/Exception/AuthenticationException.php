<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Exception;

/** 401/403 — the token is wrong, expired or lacks the scope. */
class AuthenticationException extends ApiException {}
