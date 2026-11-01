<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Exception;

/** 429 — still rate limited after retries; see $retryAfter. */
class RateLimitException extends ApiException {}
