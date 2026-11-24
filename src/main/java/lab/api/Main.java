package lab.api;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

/**
 * Startup order: config from S3 -> database pool -> HTTP server.
 * Exit codes systemd will see:
 *   2 = configuration could not be loaded or is invalid
 *   4 = database unreachable or credentials rejected at startup
 *   3 = JVM killed itself on OutOfMemoryError (-XX:+ExitOnOutOfMemoryError)
 */
public final class Main {
    public static void main(String[] args) {
        Config cfg;
        try {
            cfg = Config.load();
        } catch (Exception e) {
            Log.error("FATAL config load failed: %s", rootMessage(e));
            System.exit(2);
            return;
        }

        HikariDataSource ds;
        try {
            HikariConfig hc = new HikariConfig();
            hc.setPoolName("member-api-pool");
            hc.setJdbcUrl(cfg.dbUrl);
            hc.setUsername(cfg.dbUser);
            hc.setPassword(cfg.dbPassword);
            hc.setMaximumPoolSize(cfg.poolSize);
            hc.setConnectionTimeout(cfg.poolTimeoutMs);
            hc.setConnectionInitSql("SET statement_timeout = '" + cfg.statementTimeoutS + "s'");
            hc.addDataSourceProperty("ApplicationName", "member-api");
            ds = new HikariDataSource(hc);
        } catch (Exception e) {
            Log.error("FATAL database init failed: %s", rootMessage(e));
            System.exit(4);
            return;
        }

        try {
            Api api = new Api(cfg, ds);
            api.start();
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                Log.info("shutdown requested, stopping");
                api.stop();
                ds.close();
            }));
        } catch (Exception e) {
            Log.error("FATAL could not start HTTP server: %s", rootMessage(e));
            ds.close();
            System.exit(1);
        }
    }

    private static String rootMessage(Throwable e) {
        Throwable t = e;
        while (t.getCause() != null && t.getCause() != t) t = t.getCause();
        return t.getClass().getSimpleName() + ": " + t.getMessage();
    }
}
