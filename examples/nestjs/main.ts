// src/main.ts - Fastify adapter, loopback bind, trust only the local proxy, drain on SIGTERM.
import { NestFactory } from "@nestjs/core";
import { FastifyAdapter, NestFastifyApplication } from "@nestjs/platform-fastify";
import { AppModule } from "./app.module";

async function bootstrap() {
  const app = await NestFactory.create<NestFastifyApplication>(
    AppModule,
    new FastifyAdapter({ trustProxy: "127.0.0.1" }), // X-Forwarded-* from Nginx only
  );
  app.enableShutdownHooks(); // SIGTERM: stop accepting, run onApplicationShutdown (closes the pool), exit
  await app.listen(Number(process.env.PORT ?? 3001), process.env.HOST ?? "127.0.0.1");
}
bootstrap();
