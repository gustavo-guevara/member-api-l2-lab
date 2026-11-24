package lab.api;

import java.io.StringReader;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;

/**
 * Runtime configuration, downloaded from S3 at startup:
 *   s3://member-api-config/application.properties
 * A bad file here stops the service from starting (see RUNBOOK INC-03).
 */
final class Config {
    final int port;
    final String dbUrl;
    final String dbUser;
    final String dbPassword;
    final int poolSize;
    final int poolTimeoutMs;
    final int statementTimeoutS;
    final String logDir;
    final String source;

    private Config(Properties p, String source) {
        this.source = source;
        this.port = intProp(p, "server.port");
        this.dbUrl = required(p, "db.url");
        this.dbUser = required(p, "db.user");
        this.dbPassword = required(p, "db.password");
        this.poolSize = intProp(p, "db.pool.size");
        this.poolTimeoutMs = intProp(p, "db.pool.timeout.ms");
        this.statementTimeoutS = intProp(p, "db.statement.timeout.s");
        this.logDir = required(p, "log.dir");
    }

    static Config load() throws Exception {
        String text;
        String source;
        String localFile = System.getenv("CONFIG_FILE");
        if (localFile != null && !localFile.isBlank()) {
            text = Files.readString(Path.of(localFile));
            source = localFile;
        } else {
            String bucket = env("CONFIG_BUCKET", "member-api-config");
            String key = env("CONFIG_KEY", "application.properties");
            try (S3Client s3 = S3Client.builder()
                    .endpointOverride(localEndpoint())
                    .forcePathStyle(true)
                    .region(Region.of(env("AWS_REGION", "us-east-1")))
                    .httpClientBuilder(UrlConnectionHttpClient.builder())
                    .build()) {
                text = s3.getObjectAsBytes(b -> b.bucket(bucket).key(key)).asString(StandardCharsets.UTF_8);
            }
            source = "s3://" + bucket + "/" + key;
        }
        Properties p = new Properties();
        p.load(new StringReader(text));
        Config c = new Config(p, source);
        Log.info("config loaded from %s port=%d pool.size=%d pool.timeout.ms=%d statement.timeout.s=%d",
                source, c.port, c.poolSize, c.poolTimeoutMs, c.statementTimeoutS);
        return c;
    }

    /** Never talk to real AWS from this lab. */
    private static URI localEndpoint() {
        String endpoint = System.getenv("AWS_ENDPOINT_URL");
        if (endpoint == null || endpoint.isBlank()) {
            throw new IllegalStateException("AWS_ENDPOINT_URL is not set (source scripts/env.sh)");
        }
        URI uri = URI.create(endpoint);
        if (!"127.0.0.1".equals(uri.getHost()) && !"localhost".equals(uri.getHost())) {
            throw new IllegalStateException("AWS_ENDPOINT_URL points to " + uri.getHost() + ", not a local emulator");
        }
        return uri;
    }

    private static String required(Properties p, String key) {
        String v = p.getProperty(key);
        if (v == null || v.isBlank()) throw new IllegalArgumentException("missing required key '" + key + "'");
        return v.trim();
    }

    private static int intProp(Properties p, String key) {
        String v = required(p, key);
        try {
            return Integer.parseInt(v);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("key '" + key + "' must be a number, got '" + v + "'");
        }
    }

    private static String env(String name, String fallback) {
        String v = System.getenv(name);
        return v == null || v.isBlank() ? fallback : v;
    }
}
