<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Unit;

use Simtabi\ServerInfraWorkbench\Console\Progress;
use Simtabi\ServerInfraWorkbench\Security\Credentials;
use Simtabi\ServerInfraWorkbench\Support\Env;
use Simtabi\ServerInfraWorkbench\Tests\TestCase;

/** The rename (ADR 0014): SIWO_* settings, with the pre-rename VSW_* names and config paths as fallbacks. */
final class EnvTest extends TestCase
{
    public function test_new_name_wins_and_old_name_is_the_fallback(): void
    {
        self::assertSame('new', Env::get('SIWO_PROGRESS', ['SIWO_PROGRESS' => 'new', 'VSW_PROGRESS' => 'old']));
        self::assertSame('old', Env::get('SIWO_PROGRESS', ['VSW_PROGRESS' => 'old']));
        self::assertSame('old', Env::get('SIWO_PROGRESS', ['SIWO_PROGRESS' => '', 'VSW_PROGRESS' => 'old']));
        self::assertNull(Env::get('SIWO_PROGRESS', []));
        self::assertNull(Env::get('DIGITALOCEAN_TOKEN', ['VSW_DIGITALOCEAN_TOKEN' => 'x']), 'only SIWO_* names have a fallback');
    }

    public function test_legacy_names_in_use_are_listed_for_the_notice(): void
    {
        self::assertSame(['VSW_AUDIT_LOG', 'VSW_QUIET'], Env::legacyInUse(['VSW_QUIET' => '1', 'SIWO_X' => '1', 'VSW_AUDIT_LOG' => 'off', 'VSW_EMPTY' => '']));
        self::assertSame(['SIWO_QUIET' => '1', 'VSW_QUIET' => '0'], Env::withFallbacks(['SIWO_QUIET' => '1', 'VSW_QUIET' => '0']));
        self::assertSame(['VSW_QUIET' => '1', 'SIWO_QUIET' => '1'], Env::withFallbacks(['VSW_QUIET' => '1']));
    }

    public function test_progress_honours_the_old_names(): void
    {
        $stream = fopen('php://memory', 'w+');
        self::assertNotFalse($stream);
        self::assertSame(Progress::OFF, Progress::detect($stream, ['VSW_QUIET' => '1'], true)->mode());
        self::assertSame(Progress::PLAIN, Progress::detect($stream, ['VSW_PROGRESS' => 'plain', 'TERM' => 'xterm'], true)->mode());
        self::assertSame(Progress::PLAIN, Progress::detect($stream, ['SIWO_PROGRESS' => 'plain', 'VSW_PROGRESS' => 'off', 'TERM' => 'xterm'], true)->mode());
    }

    public function test_settings_fall_back_in_env_and_in_the_credentials_file(): void
    {
        self::assertSame('ubuntu-24-04-x64', (new Credentials('/nonexistent', ['VSW_DROPLET_IMAGE' => 'ubuntu-24-04-x64']))->setting('SIWO_DROPLET_IMAGE'));
        $dir = $this->tempDir();
        $file = $dir.'/credentials';
        file_put_contents($file, "VSW_DROPLET_IMAGE=ubuntu-22-04-x64\n");
        chmod($file, 0o600);
        self::assertSame('ubuntu-22-04-x64', (new Credentials($file, []))->setting('SIWO_DROPLET_IMAGE'));
        file_put_contents($file, "SIWO_DROPLET_IMAGE=new\nVSW_DROPLET_IMAGE=old\n");
        self::assertSame('new', (new Credentials($file, []))->setting('SIWO_DROPLET_IMAGE'));
    }

    public function test_user_path_uses_the_old_directory_only_while_the_new_one_is_missing(): void
    {
        $home = $this->tempDir();
        self::assertSame($home.'/.config/server-infra-workbench/credentials', Env::userPath($home, '.config/{name}/credentials'));
        mkdir($home.'/.config/vps-server-workbench', 0o700, true);
        touch($home.'/.config/vps-server-workbench/credentials');
        self::assertSame($home.'/.config/vps-server-workbench/credentials', Env::userPath($home, '.config/{name}/credentials'));
        mkdir($home.'/.config/server-infra-workbench', 0o700, true);
        touch($home.'/.config/server-infra-workbench/credentials');
        self::assertSame($home.'/.config/server-infra-workbench/credentials', Env::userPath($home, '.config/{name}/credentials'));
    }
}
