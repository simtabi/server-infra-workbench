<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Exception;

/** 429 — still rate limited after retries; see $retryAfter. */
class RateLimitException extends ApiException {}
