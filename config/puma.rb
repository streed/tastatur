# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1. You can set it to `auto` to automatically start a worker
# for each available processor.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Refuse a request body larger than 64 KB.
#
# `POST /api/event` is unauthenticated and callable by anything, and it used to
# accept a body of any size at all — a 5 MB beacon was measured being answered
# 202. Every byte of that is read, parsed as JSON and held in memory by a thread
# that could have been serving a real pageview, so an attacker gets a large
# multiplier on their own bandwidth for free.
#
# 64 KB against a largest-legitimate beacon of ~17.4 KB, which is what the ingest
# contract's own bounds allow: 2 x 2,048 for the URL and referrer, 120 for the
# event name, and 24 properties of 60 + 500. That is 3.6x headroom.
#
# Safe to apply globally rather than per-path: this application has no file
# uploads anywhere (no `file_field`, no `has_one_attached`), and every form post it
# serves is a few hundred bytes. Adding an upload later means raising this, and the
# symptom would be an obvious 413 rather than anything subtle.
#
# Caddy enforces the same limit at the edge for the ingest paths, so on the bundled
# stack an oversized body is dropped before it reaches Ruby at all.
http_content_length_limit 64 * 1024

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
