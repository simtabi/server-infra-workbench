<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Exception;

/** 404 — the resource does not exist (or the token cannot see it). */
class NotFoundException extends ApiException {}
