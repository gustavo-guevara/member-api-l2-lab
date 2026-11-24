package lab.api;

import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.SQLTransientConnectionException;
import java.sql.Statement;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import com.zaxxer.hikari.HikariDataSource;
import com.zaxxer.hikari.HikariPoolMXBean;

/**
 * Member API endpoints:
 *   GET  /health
 *   GET  /members/{id}
 *   GET  /members?last_name=Lopez
 *   GET  /claims?member_id=MBR-000123
 *   POST /claims/{id}/status?value=APPROVED
 *   GET  /reports/claims?from=2026-11-01&to=2026-11-07
 */
final class Api {
    static final String VERSION = "1.0.0";
    private static final Set<String> STATUSES = Set.of("SUBMITTED", "IN_REVIEW", "APPROVED", "DENIED", "PAID");

    private record Response(int status, String body) {}

    private static final class HttpError extends RuntimeException {
        final int status;
        HttpError(int status, String message) {
            super(message);
            this.status = status;
        }
    }

    private final Config cfg;
    private final HikariDataSource ds;
    private final AccessLog accessLog;
    private final long startedAt = System.currentTimeMillis();
    private HttpServer server;
    private ExecutorService workers;

    Api(Config cfg, HikariDataSource ds) {
        this.cfg = cfg;
        this.ds = ds;
        this.accessLog = new AccessLog(cfg.logDir);
    }

    void start() throws IOException {
        server = HttpServer.create(new InetSocketAddress("0.0.0.0", cfg.port), 0);
        workers = Executors.newFixedThreadPool(32);
        server.setExecutor(workers);
        server.createContext("/", this::handle);
        server.start();
        Log.info("member-api %s listening on port %d", VERSION, cfg.port);
    }

    void stop() {
        if (server != null) server.stop(1);
        if (workers != null) workers.shutdownNow();
    }

    // ---------- request handling ----------

    private void handle(HttpExchange ex) throws IOException {
        long t0 = System.nanoTime();
        String method = ex.getRequestMethod();
        String target = ex.getRequestURI().toString();
        Response r;
        try {
            r = route(method, ex.getRequestURI().getPath(), parseQuery(ex.getRequestURI().getRawQuery()));
        } catch (HttpError e) {
            r = new Response(e.status, error(e.getMessage()));
        } catch (SQLTransientConnectionException e) {
            // HikariCP: no free connection within db.pool.timeout.ms
            Log.warn("pool exhausted on %s %s: %s %s", method, target, e.getMessage(), poolStats());
            r = new Response(503, error("database connection pool exhausted"));
        } catch (SQLException e) {
            boolean timeout = "57014".equals(e.getSQLState());
            Log.error("%s on %s %s sqlstate=%s: %s", timeout ? "statement timeout" : "SQL error",
                    method, target, e.getSQLState(), e.getMessage());
            r = new Response(timeout ? 504 : 500, error(timeout ? "query timed out" : "database error"));
        } catch (Exception e) {
            Log.error("unexpected %s on %s %s: %s", e.getClass().getSimpleName(), method, target, e.getMessage());
            r = new Response(500, error("internal error"));
        }
        byte[] bytes = r.body().getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(r.status(), bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
        accessLog.write(method, target, r.status(), (System.nanoTime() - t0) / 1_000_000);
    }

    private Response route(String method, String path, Map<String, String> q) throws SQLException {
        String[] parts = path.replaceAll("/+$", "").split("/");
        // parts[0] is "" because the path starts with "/"
        if (path.equals("/health")) return health();
        if (parts.length == 3 && parts[1].equals("members")) return get(method, memberById(parts[2]));
        if (path.equals("/members")) return get(method, membersByLastName(need(q, "last_name")));
        if (path.equals("/claims")) return get(method, claimsByMember(need(q, "member_id")));
        if (parts.length == 4 && parts[1].equals("claims") && parts[3].equals("status")) {
            if (!method.equals("POST")) throw new HttpError(405, "use POST");
            return updateClaimStatus(parts[2], need(q, "value"));
        }
        if (path.equals("/reports/claims")) return get(method, claimsReport(need(q, "from"), need(q, "to")));
        throw new HttpError(404, "no such endpoint: " + path);
    }

    private static Response get(String method, Response r) {
        if (!method.equals("GET")) throw new HttpError(405, "use GET");
        return r;
    }

    // ---------- endpoints ----------

    private Response health() {
        String db = "UP";
        String dbError = null;
        try (Connection c = ds.getConnection(); Statement s = c.createStatement()) {
            s.execute("SELECT 1");
        } catch (SQLException e) {
            db = "DOWN";
            dbError = e.getMessage();
        }
        File logDir = new File(cfg.logDir);
        long total = logDir.getTotalSpace();
        long freePct = total == 0 ? -1 : logDir.getUsableSpace() * 100 / total;
        HikariPoolMXBean pool = ds.getHikariPoolMXBean();
        int waiting = pool == null ? 0 : pool.getThreadsAwaitingConnection();

        String status = db.equals("DOWN") ? "DOWN"
                : (freePct >= 0 && freePct < 10) || waiting > 0 ? "DEGRADED" : "UP";
        String body = "{\"status\":\"" + status + "\",\"version\":\"" + VERSION + "\""
                + ",\"uptime_s\":" + (System.currentTimeMillis() - startedAt) / 1000
                + ",\"db\":\"" + db + "\""
                + (dbError == null ? "" : ",\"db_error\":" + str(dbError))
                + ",\"pool\":" + poolStats()
                + ",\"log_disk_free_pct\":" + freePct + "}";
        return new Response(status.equals("DOWN") ? 503 : 200, body);
    }

    private Response memberById(String id) throws SQLException {
        List<String> rows = query("SELECT * FROM members WHERE member_id = ?", id);
        if (rows.isEmpty()) throw new HttpError(404, "member not found: " + id);
        return new Response(200, rows.get(0));
    }

    private Response membersByLastName(String lastName) throws SQLException {
        return new Response(200, list(query(
                "SELECT member_id, first_name, last_name, plan_code FROM members WHERE last_name = ? LIMIT 50",
                lastName)));
    }

    private Response claimsByMember(String memberId) throws SQLException {
        return new Response(200, list(query(
                "SELECT claim_id, service_date, amount, status FROM claims "
                        + "WHERE member_id = ? ORDER BY service_date DESC LIMIT 100", memberId)));
    }

    private Response updateClaimStatus(String claimId, String value) throws SQLException {
        if (!STATUSES.contains(value)) throw new HttpError(400, "invalid status " + value + ", allowed " + STATUSES);
        long id;
        try {
            id = Long.parseLong(claimId);
        } catch (NumberFormatException e) {
            throw new HttpError(400, "claim id must be a number");
        }
        try (Connection c = ds.getConnection();
             PreparedStatement ps = c.prepareStatement(
                     "UPDATE claims SET status = ?, updated_at = now() WHERE claim_id = ?")) {
            ps.setString(1, value);
            ps.setLong(2, id);
            if (ps.executeUpdate() == 0) throw new HttpError(404, "claim not found: " + id);
        }
        return new Response(200, "{\"claim_id\":" + id + ",\"status\":\"" + value + "\"}");
    }

    /**
     * Known issue (INC-05): loads every row of the range into memory before answering.
     * A small range is fine; a full year exhausts the heap and the JVM exits.
     */
    private Response claimsReport(String from, String to) throws SQLException {
        LocalDate f, t;
        try {
            f = LocalDate.parse(from);
            t = LocalDate.parse(to);
        } catch (Exception e) {
            throw new HttpError(400, "from/to must be YYYY-MM-DD");
        }
        List<String> rows = query(
                "SELECT claim_id, member_id, service_date, amount, status FROM claims "
                        + "WHERE service_date BETWEEN ? AND ? ORDER BY service_date",
                java.sql.Date.valueOf(f), java.sql.Date.valueOf(t));
        return new Response(200, "{\"from\":\"" + f + "\",\"to\":\"" + t + "\",\"count\":" + rows.size()
                + ",\"rows\":" + list(rows) + "}");
    }

    // ---------- helpers ----------

    private List<String> query(String sql, Object... params) throws SQLException {
        try (Connection c = ds.getConnection(); PreparedStatement ps = c.prepareStatement(sql)) {
            for (int i = 0; i < params.length; i++) ps.setObject(i + 1, params[i]);
            try (ResultSet rs = ps.executeQuery()) {
                ResultSetMetaData md = rs.getMetaData();
                List<String> rows = new ArrayList<>();
                while (rs.next()) {
                    StringBuilder sb = new StringBuilder("{");
                    for (int i = 1; i <= md.getColumnCount(); i++) {
                        if (i > 1) sb.append(',');
                        Object v = rs.getObject(i);
                        sb.append('"').append(md.getColumnLabel(i)).append("\":");
                        sb.append(v == null ? "null" : v instanceof Number ? v.toString() : str(v.toString()));
                    }
                    rows.add(sb.append('}').toString());
                }
                return rows;
            }
        }
    }

    private String poolStats() {
        HikariPoolMXBean p = ds.getHikariPoolMXBean();
        if (p == null) return "{}";
        return "{\"active\":" + p.getActiveConnections() + ",\"idle\":" + p.getIdleConnections()
                + ",\"waiting\":" + p.getThreadsAwaitingConnection() + ",\"total\":" + p.getTotalConnections()
                + ",\"max\":" + cfg.poolSize + "}";
    }

    private static String list(List<String> rows) {
        return "[" + String.join(",", rows) + "]";
    }

    private static String error(String msg) {
        return "{\"error\":" + str(msg) + "}";
    }

    private static String str(String s) {
        StringBuilder sb = new StringBuilder("\"");
        for (char ch : s.toCharArray()) {
            switch (ch) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (ch < 0x20) sb.append(String.format("\\u%04x", (int) ch));
                    else sb.append(ch);
                }
            }
        }
        return sb.append('"').toString();
    }

    private static Map<String, String> parseQuery(String raw) {
        Map<String, String> q = new HashMap<>();
        if (raw == null || raw.isEmpty()) return q;
        for (String pair : raw.split("&")) {
            int i = pair.indexOf('=');
            if (i > 0) {
                q.put(URLDecoder.decode(pair.substring(0, i), StandardCharsets.UTF_8),
                        URLDecoder.decode(pair.substring(i + 1), StandardCharsets.UTF_8));
            }
        }
        return q;
    }

    private static String need(Map<String, String> q, String name) {
        String v = q.get(name);
        if (v == null || v.isBlank()) throw new HttpError(400, "missing query parameter '" + name + "'");
        return v;
    }
}
