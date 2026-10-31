# php-fpm for Laravel with PostgreSQL and MySQL drivers. Adjust to your app.
ARG PHP_VERSION=8.5
FROM php:${PHP_VERSION}-fpm
RUN apt-get -o Acquire::Retries=5 update \
 && apt-get -o Acquire::Retries=5 install -y --no-install-recommends libpq-dev libzip-dev libicu-dev unzip \
 && docker-php-ext-install -j"$(nproc)" pdo_pgsql pdo_mysql bcmath intl zip opcache pcntl \
 && rm -rf /var/lib/apt/lists/*
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /var/www/html
