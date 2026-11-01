<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Unit;

use Simtabi\ServerInfraWorkbench\Exception\ConfirmationRequiredException;
use Simtabi\ServerInfraWorkbench\Exception\TransportException;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Keys\ServerKeys;
use Simtabi\ServerInfraWorkbench\Tests\Fixtures\FakeKeys;
use Simtabi\ServerInfraWorkbench\Tests\Fixtures\FakeSshRunner;
use Simtabi\ServerInfraWorkbench\Tests\TestCase;

final class ServerKeysTest extends TestCase
{
    private FakeSshRunner $ssh;

    private string $mine;

    private string $other;

    private string $third;

    protected function setUp(): void
    {
        parent::setUp();
        $this->ssh = new FakeSshRunner;
        $this->mine = FakeKeys::ed25519('me@laptop', 1);
        $this->other = FakeKeys::ed25519('ci@runner', 2);
        $this->third = FakeKeys::ed25519('old@desktop', 3);
        $this->ssh->file = "{$this->mine}\n{$this->other}\n{$this->third}\n";
        $this->ssh->sessionFingerprint = FakeKeys::fingerprint($this->mine);
    }

    /** @param list<string> $local */
    private function server(array $local = []): ServerKeys
    {
        return new ServerKeys($this->ssh, 'root@db-01', ['-p', '2222'], $this->audit, $local, '/tmp');
    }

    public function test_lists_entries_and_detects_the_session_key(): void
    {
        $server = $this->server();
        self::assertSame(3, count($server->entries()));
        self::assertSame(FakeKeys::fingerprint($this->mine), $server->sessionFingerprint());
        self::assertSame(['-p', '2222', '-o', 'ControlPath=none', '-v'], $this->ssh->calls[1]['options']);
        self::assertContains('ControlMaster=auto', $this->ssh->calls[0]['options']);
    }

    public function test_never_removes_the_current_session_key_even_with_force(): void
    {
        $this->expectException(ValidationException::class);
        $this->expectExceptionMessage('current session logged in with');
        $this->server()->remove('1', true);
    }

    public function test_remove_backs_up_writes_validates_and_tests_a_fresh_login(): void
    {
        $pending = $this->server()->remove('2');
        self::assertFalse($pending->isDestructive());
        self::assertSame(['remove' => FakeKeys::fingerprint($this->other), 'lines' => 1, 'keysAfter' => 2], $pending->plan()['payload']);
        self::assertSame("{$this->mine}\n{$this->other}\n{$this->third}\n", $this->ssh->file, 'plan changes nothing');

        $backup = $pending->confirm();
        self::assertMatchesRegularExpression('/^authorized_keys\.bak\.\d{8}-\d{6}$/', $backup);
        self::assertSame("{$this->mine}\n{$this->third}\n", $this->ssh->file);
        self::assertSame("{$this->mine}\n{$this->other}\n{$this->third}\n", $this->ssh->backups[$backup]);
        $write = array_values(array_filter($this->ssh->commands(), static fn (string $c): bool => str_contains($c, '.new')))[0];
        self::assertStringContainsString('umask 077', $write);
        self::assertStringContainsString('chmod 700 ~/.ssh', $write);
        self::assertStringContainsString('mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys', $write);
        $fresh = array_filter($this->ssh->calls, static fn (array $c): bool => in_array('ControlPath=none', $c['options'], true) && ! in_array('-v', $c['options'], true));
        self::assertCount(1, $fresh);
        self::assertSame(['dry-run', 'confirmed', 'succeeded'], $this->audit->outcomes());
    }

    public function test_failed_fresh_login_restores_the_backup(): void
    {
        $this->ssh->freshLoginExit = 255;
        $before = $this->ssh->file;
        try {
            $this->server()->remove('3')->confirm();
            self::fail('expected TransportException');
        } catch (TransportException $e) {
            self::assertStringContainsString('fresh login failed', $e->getMessage());
        }
        self::assertSame($before, $this->ssh->file);
    }

    public function test_bad_read_back_restores_the_backup(): void
    {
        $this->ssh->corruptWrite = true;
        $before = $this->ssh->file;
        $this->expectException(TransportException::class);
        $this->expectExceptionMessage('did not read back');
        try {
            $this->server()->remove('3')->confirm();
        } finally {
            self::assertSame($before, $this->ssh->file);
        }
    }

    public function test_last_key_local_key_and_unknown_session_need_force(): void
    {
        $this->ssh->file = "{$this->other}\n";
        $this->ssh->sessionFingerprint = FakeKeys::fingerprint($this->mine);
        try {
            $this->server()->remove('1');
            self::fail('last key');
        } catch (ConfirmationRequiredException $e) {
            self::assertStringContainsString('last key', $e->getMessage());
        }
        self::assertSame(0, $this->server()->remove('1', true)->plan()['payload']['keysAfter']);

        $this->ssh->file = "{$this->mine}\n{$this->other}\n";
        try {
            $this->server([$this->other])->remove('2');
            self::fail('local key');
        } catch (ConfirmationRequiredException $e) {
            self::assertStringContainsString('local ~/.ssh/*.pub', $e->getMessage());
        }

        $this->ssh->sessionFingerprint = null;
        $this->expectException(ConfirmationRequiredException::class);
        $this->expectExceptionMessage('could not tell which key');
        $this->server()->remove('2');
    }

    public function test_emptying_the_file_skips_the_fresh_login_test(): void
    {
        $this->ssh->file = "{$this->other}\n";
        $this->ssh->freshLoginExit = 255;
        $this->server()->remove('1', true)->confirm();
        self::assertSame('', $this->ssh->file);
    }

    public function test_add_dedupes_and_appends(): void
    {
        self::assertTrue($this->server()->add('no-pty '.FakeKeys::ed25519('other comment', 2))->isNoop());
        $new = FakeKeys::ed25519('new@laptop', 9);
        $this->server()->add($new)->confirm();
        self::assertStringEndsWith("{$new}\n", $this->ssh->file);
        self::assertSame(4, substr_count($this->ssh->file, "\n"));
    }

    public function test_fix_permissions_and_target_validation(): void
    {
        $this->server()->fixPermissions()->confirm();
        self::assertTrue($this->ssh->permsFixed);
        foreach (['-oProxyCommand=x', 'root@host;rm', 'a b'] as $bad) {
            try {
                new ServerKeys($this->ssh, $bad, [], $this->audit);
                self::fail($bad);
            } catch (ValidationException) {
                $this->addToAssertionCount(1);
            }
        }
    }

    public function test_unknown_selector(): void
    {
        $this->expectException(ValidationException::class);
        $this->server()->remove('SHA256:doesnotexist');
    }

    public function test_local_public_keys_reads_only_pub_files(): void
    {
        $home = $this->tempDir();
        mkdir($home.'/.ssh');
        file_put_contents($home.'/.ssh/id_ed25519.pub', $this->mine."\n");
        file_put_contents($home.'/.ssh/id_ed25519', '-----BEGIN OPENSSH '."PRIVATE KEY-----\nnot a real key\n");
        file_put_contents($home.'/.ssh/broken.pub', 'junk');
        self::assertSame([$this->mine], ServerKeys::localPublicKeys($home));
    }
}
