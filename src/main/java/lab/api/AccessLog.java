package lab.api;

import java.io.FileWriter;
import java.io.IOException;
import java.nio.file.Path;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;

/**
 * One line per HTTP request:
 *   2026-11-24 10:00:00 GET /claims?member_id=MBR-000001 200 12ms
 * Opened in append mode on every write, so archive_logs.sh can truncate it safely.
 * If the disk is full, the API keeps serving and warns in the journal (INC-04).
 */
final class AccessLog {
    private static final DateTimeFormatter TS = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    private final Path file;
    private long failures;
    private long lastWarnMs;

    AccessLog(String dir) {
        this.file = Path.of(dir, "access.log");
    }

    synchronized void write(String method, String target, int status, long ms) {
        String line = LocalDateTime.now().format(TS) + " " + method + " " + target + " " + status + " " + ms + "ms\n";
        try (FileWriter w = new FileWriter(file.toFile(), true)) {
            w.write(line);
        } catch (IOException e) {
            failures++;
            long now = System.currentTimeMillis();
            if (now - lastWarnMs > 30_000) {
                Log.warn("access log write failed (%d failures so far): %s", failures, e.getMessage());
                lastWarnMs = now;
            }
        }
    }
}
