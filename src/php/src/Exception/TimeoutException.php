<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Exception;

/** Waiting for a provider action or operation took longer than allowed. */
class TimeoutException extends \RuntimeException implements WorkbenchException {}
