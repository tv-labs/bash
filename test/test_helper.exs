# Suppress Logger debug output during tests to avoid polluting stdout.
# Tests that need to assert on log messages can use ExUnit.CaptureLog.capture_log/1
Logger.configure(level: :warning)

ExUnit.start()
