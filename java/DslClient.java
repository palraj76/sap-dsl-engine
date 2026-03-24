package com.dsl.client;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * SAP JSON DSL Engine — Java Caller
 *
 * Usage:
 *   java DslClient https://sap.client.internal:8000 CLIENT_ACME_001 <secret>
 */
public class DslClient {

    private final HttpClient httpClient;
    private final String endpoint;
    private final String clientId;
    private final String clientSecret;
    private final Map<String, TokenEntry> tokenCache = new ConcurrentHashMap<>();

    public DslClient(String sapHost, String clientId, String clientSecret) {
        this.endpoint = sapHost.replaceAll("/$", "") + "/sap/zdsl";
        this.clientId = clientId;
        this.clientSecret = clientSecret;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build();
    }

    // ─── Token Management ───────────────────────────────────

    private String getToken() throws Exception {
        TokenEntry cached = tokenCache.get(clientId);
        if (cached != null && cached.expiresAt > System.currentTimeMillis() + 600_000) {
            return cached.token;
        }

        String body = String.format(
                "{\"client_id\":\"%s\",\"client_secret\":\"%s\"}",
                clientId, clientSecret);

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(endpoint + "/auth"))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .timeout(Duration.ofSeconds(10))
                .build();

        HttpResponse<String> response = httpClient.send(request,
                HttpResponse.BodyHandlers.ofString());

        if (response.statusCode() != 200) {
            throw new RuntimeException("Auth failed: " + response.statusCode()
                    + " " + response.body());
        }

        // Simple JSON parsing (no external dependency)
        String responseBody = response.body();
        String token = extractJsonString(responseBody, "access_token");
        int expiresIn = extractJsonInt(responseBody, "expires_in");

        tokenCache.put(clientId, new TokenEntry(token,
                System.currentTimeMillis() + expiresIn * 1000L));
        return token;
    }

    private void invalidateToken() {
        tokenCache.remove(clientId);
    }

    // ─── Query Execution ────────────────────────────────────

    public String query(String payloadJson) throws Exception {
        String token = getToken();
        String requestId = UUID.randomUUID().toString();

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(endpoint + "/query"))
                .header("Content-Type", "application/json")
                .header("Authorization", "Bearer " + token)
                .header("X-DSL-Client-ID", clientId)
                .header("X-DSL-Request-ID", requestId)
                .POST(HttpRequest.BodyPublishers.ofString(payloadJson))
                .timeout(Duration.ofSeconds(35))
                .build();

        HttpResponse<String> response = httpClient.send(request,
                HttpResponse.BodyHandlers.ofString());

        if (response.statusCode() == 401) {
            invalidateToken();
            return query(payloadJson); // retry once
        }

        if (response.statusCode() >= 400) {
            System.err.println("HTTP " + response.statusCode() + ": " + response.body());
        }

        return response.body();
    }

    // ─── Query Builders ─────────────────────────────────────

    public static String buildUserQuery(int limit) {
        String queryId = "Q-JAVA-" + UUID.randomUUID().toString().substring(0, 8);
        return String.format(
                "{\"version\":\"1.3\"," +
                "\"query_id\":\"%s\"," +
                "\"sources\":[{\"table\":\"USR02\",\"alias\":\"u\"}]," +
                "\"select\":[" +
                "  {\"field\":\"u.BNAME\",\"alias\":\"user\",\"type\":\"STRING\"}," +
                "  {\"field\":\"u.USTYP\",\"alias\":\"user_type\",\"type\":\"STRING\"}," +
                "  {\"field\":\"u.TRDAT\",\"alias\":\"last_login\",\"type\":\"DATE\"}" +
                "]," +
                "\"filters\":{\"logic\":\"AND\",\"conditions\":[" +
                "  {\"field\":\"u.USTYP\",\"op\":\"IN\",\"value\":[\"A\",\"B\"]}" +
                "]}," +
                "\"order_by\":[{\"field\":\"u.BNAME\",\"direction\":\"asc\"}]," +
                "\"limit\":{\"rows\":%d}}", queryId, limit);
    }

    public static String buildUserRoleQuery(String asOfDate, int limit) {
        String queryId = "Q-JAVA-" + UUID.randomUUID().toString().substring(0, 8);
        return String.format(
                "{\"version\":\"1.3\"," +
                "\"query_id\":\"%s\"," +
                "\"sources\":[{\"table\":\"USR02\",\"alias\":\"u\"}]," +
                "\"joins\":[{" +
                "  \"type\":\"left\"," +
                "  \"target\":{\"table\":\"AGR_USERS\",\"alias\":\"ru\"}," +
                "  \"on\":{\"logic\":\"AND\",\"conditions\":[" +
                "    {\"left\":\"u.BNAME\",\"op\":\"=\",\"right\":\"ru.UNAME\"}," +
                "    {\"left\":\"u.MANDT\",\"op\":\"=\",\"right\":\"ru.MANDT\"}" +
                "  ]}" +
                "}]," +
                "\"select\":[" +
                "  {\"field\":\"u.BNAME\",\"alias\":\"user\",\"type\":\"STRING\"}," +
                "  {\"field\":\"ru.AGR_NAME\",\"alias\":\"role\",\"type\":\"STRING\"}," +
                "  {\"field\":\"ru.FROM_DAT\",\"alias\":\"valid_from\",\"type\":\"DATE\"}," +
                "  {\"field\":\"ru.TO_DAT\",\"alias\":\"valid_to\",\"type\":\"DATE\"}" +
                "]," +
                "\"filters\":{\"logic\":\"AND\",\"conditions\":[" +
                "  {\"field\":\"u.USTYP\",\"op\":\"=\",\"value\":\"A\"}," +
                "  {\"field\":\"ru.TO_DAT\",\"op\":\">=\",\"param\":\"asOfDate\"}" +
                "]}," +
                "\"params\":{\"asOfDate\":\"%s\"}," +
                "\"order_by\":[{\"field\":\"u.BNAME\",\"direction\":\"asc\"}]," +
                "\"limit\":{\"rows\":%d,\"page_size\":50}}", queryId, asOfDate, limit);
    }

    public static String buildEntityQuery() {
        String queryId = "Q-JAVA-" + UUID.randomUUID().toString().substring(0, 8);
        return String.format(
                "{\"version\":\"1.3\"," +
                "\"query_id\":\"%s\"," +
                "\"entity\":\"user_access\"," +
                "\"select\":[" +
                "  {\"alias\":\"user\"}," +
                "  {\"alias\":\"role\"}," +
                "  {\"alias\":\"auth_object\"}" +
                "]," +
                "\"filters\":{\"logic\":\"AND\",\"conditions\":[" +
                "  {\"field\":\"user_type\",\"op\":\"IN\",\"value\":[\"A\",\"B\"]}" +
                "]}," +
                "\"limit\":{\"rows\":50}}", queryId);
    }

    // ─── Minimal JSON helpers (no external deps) ────────────

    private static String extractJsonString(String json, String key) {
        String search = "\"" + key + "\":\"";
        int start = json.indexOf(search);
        if (start < 0) return "";
        start += search.length();
        int end = json.indexOf("\"", start);
        return json.substring(start, end);
    }

    private static int extractJsonInt(String json, String key) {
        String search = "\"" + key + "\":";
        int start = json.indexOf(search);
        if (start < 0) return 0;
        start += search.length();
        StringBuilder sb = new StringBuilder();
        for (int i = start; i < json.length(); i++) {
            char c = json.charAt(i);
            if (Character.isDigit(c)) sb.append(c);
            else break;
        }
        return sb.length() > 0 ? Integer.parseInt(sb.toString()) : 0;
    }

    private static class TokenEntry {
        final String token;
        final long expiresAt;

        TokenEntry(String token, long expiresAt) {
            this.token = token;
            this.expiresAt = expiresAt;
        }
    }

    // ─── Main ───────────────────────────────────────────────

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.out.println("Usage: java DslClient <sap-host> <client-id> <secret> [users|roles|entity] [limit]");
            System.out.println("Example: java DslClient https://sap.acme.internal:8000 CLIENT_001 mysecret users 10");
            return;
        }

        String host = args[0];
        String clientId = args[1];
        String secret = args[2];
        String queryType = args.length > 3 ? args[3] : "users";
        int limit = args.length > 4 ? Integer.parseInt(args[4]) : 10;

        DslClient client = new DslClient(host, clientId, secret);

        String payload;
        switch (queryType) {
            case "roles":
                payload = buildUserRoleQuery("20260324", limit);
                break;
            case "entity":
                payload = buildEntityQuery();
                break;
            default:
                payload = buildUserQuery(limit);
        }

        System.out.println("Endpoint: " + host + "/sap/zdsl/query");
        System.out.println("Client:   " + clientId);
        System.out.println("Query:    " + queryType);
        System.out.println("\nPayload:\n" + payload);

        String result = client.query(payload);

        System.out.println("\nResponse:\n" + result);
    }
}
