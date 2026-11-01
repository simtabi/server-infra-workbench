// src/db.module.ts - TypeORM with no password option: the pg driver underneath reads PGHOST PGPORT
// PGDATABASE PGUSER and the password from PGPASSFILE (600). Nothing secret in code, env or a URL.
import { Module } from "@nestjs/common";
import { TypeOrmModule } from "@nestjs/typeorm";

@Module({
  imports: [
    TypeOrmModule.forRoot({
      type: "postgres",
      host: process.env.PGHOST,
      port: Number(process.env.PGPORT),
      database: process.env.PGDATABASE,
      username: process.env.PGUSER,
      ssl: process.env.PGSSLMODE === "require" || process.env.PGSSLMODE === "verify-full"
        ? { rejectUnauthorized: process.env.PGSSLMODE === "verify-full" }
        : false,
      extra: { max: 5, connectionTimeoutMillis: 5000 },
      autoLoadEntities: true,
      synchronize: false, // schema changes only through migrations (the deploy runs them)
      migrationsRun: false,
    }),
  ],
})
export class DbModule {}
