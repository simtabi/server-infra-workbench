# config/puma.rb - loopback only, workers + threads from the env, Solid Queue as a Puma plugin.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3).to_i
threads threads_count, threads_count
workers ENV.fetch("WEB_CONCURRENCY", 2).to_i
bind "tcp://127.0.0.1:#{ENV.fetch('PORT', 3000)}"   # never 0.0.0.0: Nginx is the public side
preload_app!                                         # copy-on-write: less RAM per worker
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]    # jobs run in the Puma process tree, no extra daemon
worker_timeout 30
