# ============================================================
# Synapse Logging Configuration — TEMPLATE
# ============================================================
# This file is processed by scripts/init-synapse.sh.
# Output: data/synapse/log.config
#
# Log levels: DEBUG, INFO, WARNING, ERROR, CRITICAL
# Production default: WARNING (reduces log volume significantly)
# ============================================================

version: 1

formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
  # ── Console handler (captured by Docker logs) ─────────────
  console:
    class: logging.StreamHandler
    formatter: precise

  # ── File handler (rotated daily, 7 days retention) ────────
  file:
    class: logging.handlers.TimedRotatingFileHandler
    formatter: precise
    filename: /data/logs/homeserver.log
    when: midnight
    backupCount: 7
    encoding: utf8

loggers:
  # Reduce SQL query logging noise in production
  synapse.storage.SQL:
    level: WARNING

  # Reduce federation logging to WARNING in production
  # (change to INFO or DEBUG to diagnose federation issues)
  synapse.federation:
    level: WARNING

  # Reduce media download noise
  synapse.media:
    level: WARNING

  # Reduce replication noise if not using workers
  synapse.replication:
    level: WARNING

root:
  level: WARNING
  handlers:
    - console
    - file

disable_existing_loggers: false
