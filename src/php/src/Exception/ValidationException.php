<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Exception;

/** Bad input, caught before any request is made. */
class ValidationException extends \InvalidArgumentException implements WorkbenchException {}
