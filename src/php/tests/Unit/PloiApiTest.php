<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Tests\Unit;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Ploi\Ploi;
use Simtabi\ServerInfraWorkbench\Tests\TestCase;

/** Ploi sites create/delete, deploy scripts and daemons. All mocked. */
final class PloiApiTest extends TestCase
{
    private function server(): \Simtabi\ServerInfraWorkbench\Ploi\ServerResource
    {
        return Ploi::make(self::fake('ploi'), $this->options())->servers()->find(12);
    }

    public function test_site_create_is_idempotent_and_validates(): void
    {
        $this->http->json(['data' => [], 'meta' => ['current_page' => 1, 'last_page' => 1]])
            ->json(['data' => ['id' => 40, 'server_id' => 12, 'domain' => 'app.example.com', 'status' => 'creating']], 201);
        $create = $this->server()->sites()->create('app.example.com', '/public', 'laravel');
        self::assertSame(['root_domain' => 'app.example.com', 'web_directory' => '/public', 'project_root' => '/', 'system_user' => 'ploi', 'project_type' => 'laravel'], $create->plan()['payload']);
        self::assertSame(40, $create->confirm()->id);
        self::assertSame('POST /api/servers/12/sites', $this->http->log()[1]);

        $this->http->json(['data' => [['id' => 40, 'domain' => 'app.example.com']], 'meta' => ['current_page' => 1, 'last_page' => 1]]);
        self::assertTrue($this->server()->sites()->create('app.example.com')->isNoop());

        foreach ([['not a domain', '/public', ''], ['b.example.com', '../etc', ''], ['b.example.com', '/public', 'cobol']] as [$d, $w, $t]) {
            try {
                $this->server()->sites()->create($d, $w, $t);
                self::fail($d.$w.$t);
            } catch (ValidationException) {
                $this->addToAssertionCount(1);
            }
        }
    }

    public function test_site_delete_is_destructive(): void
    {
        $this->http->json(['data' => ['id' => 40, 'server_id' => 12, 'domain' => 'app.example.com']]);
        $delete = $this->server()->sites()->delete(40);
        self::assertTrue($delete->isDestructive());
        self::assertSame('/servers/12/sites/40', $delete->plan()['path']);
    }

    public function test_deploy_script_get_set_and_noop(): void
    {
        $this->http->json(['deploy_script' => "cd /home/ploi/app\ngit pull\n"]);
        self::assertSame("cd /home/ploi/app\ngit pull\n", $this->server()->sites()->deployScript(40));

        $this->http->json(['data' => ['deploy_script' => "git pull\n"]]);
        self::assertTrue($this->server()->sites()->setDeployScript(40, "git pull\r\n")->isNoop());

        $this->http->json(['deploy_script' => "git pull\n"])->push(new \GuzzleHttp\Psr7\Response(200, [], '{}'));
        $set = $this->server()->sites()->setDeployScript(40, "git pull\ncomposer install --no-dev\n");
        self::assertSame('PATCH', $set->plan()['method']);
        self::assertStringContainsString('2 lines, was 1', $set->describe());
        self::assertTrue($set->confirm());
        self::assertSame('PATCH /api/servers/12/sites/40/deploy/script', $this->http->log()[3]);

        $this->expectException(ValidationException::class);
        $this->server()->sites()->setDeployScript(40, "  \n");
    }

    public function test_daemons_list_create_idempotent_and_delete(): void
    {
        $this->http->json(['data' => [['id' => 3, 'command' => 'php artisan horizon', 'system_user' => 'ploi', 'processes' => 1, 'status' => 'active']], 'meta' => ['current_page' => 1, 'last_page' => 1]]);
        self::assertSame('php artisan horizon', $this->server()->daemons()->list()[0]->command);

        $this->http->json(['data' => [['id' => 3, 'command' => 'php artisan horizon', 'system_user' => 'ploi']], 'meta' => ['current_page' => 1, 'last_page' => 1]]);
        self::assertTrue($this->server()->daemons()->create('php artisan horizon')->isNoop());

        $this->http->json(['data' => [], 'meta' => ['current_page' => 1, 'last_page' => 1]])->json(['data' => ['id' => 4, 'command' => 'php artisan queue:work', 'processes' => 2]], 201);
        $create = $this->server()->daemons()->create('php artisan queue:work', 'ploi', 2, '/home/ploi/app');
        self::assertSame(['command' => 'php artisan queue:work', 'system_user' => 'ploi', 'processes' => 2, 'directory' => '/home/ploi/app'], $create->plan()['payload']);
        self::assertSame(4, $create->confirm()->id);

        self::assertTrue($this->server()->daemons()->delete(4)->isDestructive());
        foreach ([["two\nlines", 1], ['ok', 99]] as [$cmd, $procs]) {
            try {
                $this->server()->daemons()->create($cmd, 'ploi', $procs);
                self::fail($cmd);
            } catch (ValidationException) {
                $this->addToAssertionCount(1);
            }
        }
    }
}
