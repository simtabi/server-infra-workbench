<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Exception;

/** The provider accepted the request but the long-running action/operation ended in error. */
class ActionFailedException extends \RuntimeException implements WorkbenchException {}
