<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Exception;

/** Bad input, caught before any request is made. */
class ValidationException extends \InvalidArgumentException implements WorkbenchException {}
