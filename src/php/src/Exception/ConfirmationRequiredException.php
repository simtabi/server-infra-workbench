<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Exception;

/** A write was attempted without explicit confirmation. */
class ConfirmationRequiredException extends \RuntimeException implements WorkbenchException {}
