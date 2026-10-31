<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Exception;

/** A credential is missing or its file is unsafe. */
class CredentialException extends \RuntimeException implements WorkbenchException {}
