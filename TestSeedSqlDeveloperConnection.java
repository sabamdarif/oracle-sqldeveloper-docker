import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Arrays;
import java.util.Map;
import java.util.Properties;
import javax.xml.parsers.DocumentBuilderFactory;
import oracle.dbtools.connections.ConnectionFactory;
import oracle.dbtools.connections.ConnectionReference;
import oracle.dbtools.connections.Location;
import oracle.dbtools.connections.StorageManager;
import oracle.dbtools.connections.StringReferencePair;
import oracle.dbtools.connections.db.DatabaseProvider;
import oracle.dbtools.connections.db.DatabaseProviderStorageFactory;
import oracle.dbtools.connections.db.ora.OracleConnectionCreator;
import oracle.dbtools.connections.security.ReferenceWorker;
import oracle.dbtools.connections.security.SecureReferencePair;
import oracle.dbtools.core.secrets.Secrets;
import oracle.dbtools.core.secrets.TextSecret;
import org.w3c.dom.Element;

/** Tests against the installed SQL Developer libraries, without launching the GUI. */
public class TestSeedSqlDeveloperConnection {
    public static void main(String[] args) throws Exception {
        Path installation = Path.of(args[0]);
        Path scratch = Path.of(args[1]);
        Properties version = new Properties();
        try (var in = Files.newInputStream(installation.resolve("sqldeveloper/bin/version.properties"))) {
            version.load(in);
        }
        String systemName = "system" + version.getProperty("VER_FULL");
        String password = "test ü 中文 spaces & < > \" ' $;* \\ and\nnewline";
        Path profile = scratch.resolve("fresh");
        check(SeedSqlDeveloperConnection.seed(installation, profile, password, "FREEPDB1"), "fresh profile not seeded");
        Path system = profile.resolve(systemName);
        Path preferences = system.resolve("o.sqldeveloper/product-preferences.xml");
        Path connections = system.resolve("o.jdeveloper.db.connection/connections.json");
        String json = Files.readString(connections);
        String xml = Files.readString(preferences);
        check(!json.contains("test ü") && !xml.contains("test ü"), "plaintext password written");
        for (Path p : Arrays.asList(preferences, connections)) {
            check(Files.getPosixFilePermissions(p).equals(PosixFilePermissions.fromString("rw-------")), "credential file not private");
        }
        check(Files.getPosixFilePermissions(profile).equals(PosixFilePermissions.fromString("rwx------")), "profile not private");
        String key = readKey(preferences);
        ConnectionReference reference = readConnection(connections);
        check("system".equals(reference.get("user").getValue()), "wrong user");
        check("FREEPDB1".equals(reference.get("serviceName").getValue()), "wrong service");
        check("thin".equals(reference.get("oraDriverType").getValue()), "must use JDBC thin");
        check("true".equals(reference.get("SavePassword").getValue()), "password not saved");
        try (TextSecret keySecret = Secrets.instance().of(key.toCharArray(), true)) {
            ReferenceWorker<char[]> worker = ReferenceWorker.createDefaultWorker(keySecret);
            var pair = SecureReferencePair.convertToSecureReference((StringReferencePair) reference.get("password"));
            try (TextSecret decoded = worker.decrypt(pair, SeedSqlDeveloperConnection.NAME)) {
                check(decoded.map(chars -> password.equals(new String(chars))), "saved password cannot be decrypted by SQL Developer");
            }
            DatabaseProvider.registerConnectionCreator("oraJDBC", OracleConnectionCreator.newInstance());
            StorageManager loaded = StorageManager.builder().location(Location.createFileLocation(connections))
                    .addEnvValue(ReferenceWorker.KEY, worker).build();
            DatabaseProvider provider = loaded.<DatabaseProvider>getStorage("jdbc")
                    .getConnection(SeedSqlDeveloperConnection.NAME, new DatabaseProviderStorageFactory());
            check(password.equals(provider.getProperty("password")), "GUI provider cannot load saved password");
            String url = provider.getConnectionURL();
            check(url.contains("localhost") && url.contains("1521") && url.contains("FREEPDB1"), "invalid JDBC connection URL");
        }
        check(!SeedSqlDeveloperConnection.seed(installation, profile, "changed", "FREE"), "repeat startup rewrote connection");
        check(json.equals(Files.readString(connections)) && xml.equals(Files.readString(preferences)), "existing profile changed");

        Path existing = scratch.resolve("existing");
        Path existingStore = existing.resolve(systemName + "/o.jdeveloper.db.connection/connections.json");
        Files.createDirectories(existingStore.getParent());
        String userData = "{\"connections\":[{\"name\":\"My connection\",\"type\":\"jdbc\",\"info\":{\"user\":\"mine\"}}]}";
        Files.writeString(existingStore, userData);
        check(!SeedSqlDeveloperConnection.seed(installation, existing, password, "FREEPDB1"), "existing store not preserved");
        check(userData.equals(Files.readString(existingStore)), "existing connections overwritten");
        check(!Files.exists(existing.resolve(systemName + "/o.sqldeveloper")), "existing profile preferences created unnecessarily");

        Path older = scratch.resolve("older");
        Files.createDirectories(older.resolve("system24.3.0"));
        check(!SeedSqlDeveloperConnection.seed(installation, older, password, "FREEPDB1"), "old profile migration suppressed");
        check(!Files.exists(older.resolve(systemName)), "new system created over old profile");

        Path keyed = scratch.resolve("keyed");
        Path keyedPrefs = keyed.resolve(systemName + "/o.sqldeveloper/product-preferences.xml");
        Files.createDirectories(keyedPrefs.getParent());
        String keyedXml = "<preferences xmlns=\"http://xmlns.oracle.com/ide/hash\"><value n=\"db.system.id\" v=\"existing-key\"/><value n=\"user.preference\" v=\"keep\"/></preferences>";
        Files.writeString(keyedPrefs, keyedXml);
        check(SeedSqlDeveloperConnection.seed(installation, keyed, password, "FREE"), "existing key not reusable");
        check(keyedXml.equals(Files.readString(keyedPrefs)), "existing preferences modified");
        check("FREE".equals(readConnection(keyed.resolve(systemName + "/o.jdeveloper.db.connection/connections.json")).get("serviceName").getValue()), "configured service ignored");

        Path unkeyed = scratch.resolve("unkeyed");
        Path unkeyedPrefs = unkeyed.resolve(systemName + "/o.sqldeveloper/product-preferences.xml");
        Files.createDirectories(unkeyedPrefs.getParent());
        Files.writeString(unkeyedPrefs, "<preferences xmlns=\"http://xmlns.oracle.com/ide/hash\"/>");
        check(!SeedSqlDeveloperConnection.seed(installation, unkeyed, password, "FREEPDB1"), "unkeyed user preferences overwritten");

        Path corrupt = scratch.resolve("corrupt");
        Path corruptPrefs = corrupt.resolve(systemName + "/o.sqldeveloper/product-preferences.xml");
        Files.createDirectories(corruptPrefs.getParent());
        Files.writeString(corruptPrefs, "<unknown/>");
        try {
            SeedSqlDeveloperConnection.seed(installation, corrupt, password, "FREEPDB1");
            throw new AssertionError("unsupported preferences accepted");
        } catch (IllegalArgumentException expected) {
            check("<unknown/>".equals(Files.readString(corruptPrefs)), "corrupt preferences overwritten");
        }

        Path empty = scratch.resolve("empty");
        try {
            SeedSqlDeveloperConnection.seed(installation, empty, "", "FREEPDB1");
            throw new AssertionError("empty password accepted");
        } catch (IllegalArgumentException expected) {
            check(!Files.exists(empty), "empty credentials created a profile");
        }
        System.out.println("ok: GUI credential loading, encrypted password round-trip, permissions and profile preservation");
    }

    private static ConnectionReference readConnection(Path path) throws Exception {
        StorageManager store = StorageManager.builder().location(Location.createFileLocation(path)).build();
        return store.<ConnectionReference>getStorage("jdbc").getConnection(SeedSqlDeveloperConnection.NAME,
                new ConnectionFactory<ConnectionReference>() {
                    public Class<ConnectionReference> getConnectionClass() { return ConnectionReference.class; }
                    public String getConnectionType() { return "jdbc"; }
                    public ConnectionReference createObject(String name, ConnectionReference ref, Map<String, ?> env) { return ref; }
                });
    }

    private static String readKey(Path preferences) throws Exception {
        var factory = DocumentBuilderFactory.newInstance();
        factory.setNamespaceAware(true);
        var doc = factory.newDocumentBuilder().parse(preferences.toFile());
        var values = doc.getElementsByTagNameNS(SeedSqlDeveloperConnection.HASH_NS, "value");
        for (int i = 0; i < values.getLength(); i++) {
            Element e = (Element) values.item(i);
            if ("db.system.id".equals(e.getAttribute("n"))) { return e.getAttribute("v"); }
        }
        throw new AssertionError("credential key missing");
    }

    private static void check(boolean condition, String message) {
        if (!condition) { throw new AssertionError(message); }
    }
}
