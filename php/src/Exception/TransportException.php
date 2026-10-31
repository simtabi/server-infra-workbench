<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Exception;

/** The request never got an HTTP response (DNS, TLS, timeout, connection reset). */
class TransportException extends \RuntimeException implements WorkbenchException {}
