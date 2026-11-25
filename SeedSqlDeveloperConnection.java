import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Map;
import java.util.Properties;
import java.util.UUID;
import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import oracle.dbtools.connections.ConnectionReference;
import oracle.dbtools.connections.Location;
import oracle.dbtools.connections.StorageManager;
import oracle.dbtools.connections.StringReferencePair;
import oracle.dbtools.connections.db.DatabaseProvider;
import oracle.dbtools.connections.security.ReferenceWorker;
import oracle.dbtools.core.secrets.Secrets;
import oracle.dbtools.core.secrets.TextSecret;
import org.w3c.dom.Document;
import org.w3c.dom.Element;

public class SeedSqlDeveloperConnection {
    static final String NAME = "Oracle Free (SYSTEM)";
    static final String HASH_NS = "http://xmlns.oracle.com/ide/hash";

    // Exception messages from credential APIs must not enter startup logs.
    public static void main(String[] args) {
        try {
            String home = System.getenv("IDE_USER_DIR");
            if (home == null || home.isBlank()) {
                home = Path.of(System.getProperty("user.home"), ".sqldeveloper").toString();
            }
            seed(Path.of(args[0]), Path.of(home), System.getenv("ORACLE_PASSWORD"),
                    System.getenv().getOrDefault("ORACLE_DATABASE", "FREEPDB1"));
        } catch (Exception e) {
            System.err.println("CONTAINER: could not create the automatic SQL Developer connection; use TNS or Basic settings instead.");
            System.exit(1);
        }
    }

    // Hard links publish files without overwriting files created by a concurrent startup.
    static boolean seed(Path installation, Path userDirectory, String password, String service) throws Exception {
        Properties version = new Properties();
        try (InputStream in = Files.newInputStream(installation.resolve("sqldeveloper/bin/version.properties"))) {
            version.load(in);
        }
        String fullVersion = version.getProperty("VER_FULL", "");
        if (!fullVersion.matches("[0-9]+(?:\\.[0-9]+)+")) {
            throw new IllegalArgumentException("Unsupported SQL Developer version");
        }
        Path system = userDirectory.resolve("system" + fullVersion);
        if (Files.exists(userDirectory)) {
            try (var entries = Files.list(userDirectory)) {
                if (entries.anyMatch(p -> p.getFileName().toString().startsWith("system") && !p.equals(system))) {
                    System.out.println("CONTAINER: keeping the existing SQL Developer profile for normal settings migration.");
                    return false;
                }
            }
            try (var files = Files.walk(userDirectory)) {
                if (files.anyMatch(p -> p.getFileName().toString().matches("connections\\.(json|xml)"))) {
                    System.out.println("CONTAINER: keeping existing SQL Developer connections unchanged.");
                    return false;
                }
            }
        }
        if (password == null || password.isEmpty() || service == null || service.isBlank()) {
            throw new IllegalArgumentException("Missing database credentials");
        }

        Path preferences = system.resolve("o.sqldeveloper/product-preferences.xml");
        Path connections = system.resolve("o.jdeveloper.db.connection/connections.json");
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setNamespaceAware(true);
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
        factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "");
        Document doc;
        if (Files.exists(preferences)) {
            doc = factory.newDocumentBuilder().parse(preferences.toFile());
            if (!HASH_NS.equals(doc.getDocumentElement().getNamespaceURI())
                    || !"preferences".equals(doc.getDocumentElement().getLocalName())) {
                throw new IllegalArgumentException("Unknown preferences format");
            }
        } else {
            doc = factory.newDocumentBuilder().newDocument();
            doc.appendChild(doc.createElementNS(HASH_NS, "preferences"));
        }
        String key = null;
        for (var child = doc.getDocumentElement().getFirstChild(); child != null; child = child.getNextSibling()) {
            if (child instanceof Element element && "db.system.id".equals(element.getAttribute("n"))) {
                key = element.getAttribute("v");
                if (key.isBlank()) {
                    throw new IllegalArgumentException("Empty credential key");
                }
            }
        }
        boolean writePreferences = key == null;
        if (writePreferences && Files.exists(preferences)) {
            System.out.println("CONTAINER: keeping existing SQL Developer preferences; save connection credentials once in the GUI.");
            return false;
        }
        if (writePreferences) {
            key = UUID.randomUUID().toString();
            Element value = doc.createElementNS(HASH_NS, "value");
            value.setAttribute("n", "db.system.id");
            value.setAttribute("v", key);
            doc.getDocumentElement().appendChild(value);
        }

        try (TextSecret keySecret = Secrets.instance().of(key.toCharArray(), true);
                TextSecret passwordSecret = Secrets.instance().of(password.toCharArray(), true)) {
            ReferenceWorker<char[]> worker = ReferenceWorker.createDefaultWorker(keySecret);
            var encrypted = worker.encrypt("password", passwordSecret, NAME);
            try (TextSecret decoded = worker.decrypt(encrypted, NAME)) {
                if (!decoded.map(chars -> password.equals(new String(chars)))) {
                    throw new IllegalStateException("Credential verification failed");
                }
            }
            var reference = new ConnectionReference.ReferenceBuilder(DatabaseProvider.class.getName());
            Map<String, String> settings = Map.ofEntries(
                    Map.entry("user", "system"), Map.entry("role", ""),
                    Map.entry("hostname", "localhost"), Map.entry("port", "1521"),
                    Map.entry("serviceName", service), Map.entry("OracleConnectionType", "BASIC"),
                    Map.entry("RaptorConnectionType", "Oracle"), Map.entry("subtype", "oraJDBC"),
                    Map.entry("driver", "oracle.jdbc.OracleDriver"), Map.entry("oraDriverType", "thin"),
                    Map.entry("SavePassword", "true"), Map.entry("NoPasswordConnection", "FALSE"),
                    Map.entry("OS_AUTHENTICATION", "false"));
            settings.forEach((k, v) -> reference.addValue(new StringReferencePair(k, v)));
            reference.addValue(encrypted);
            StorageManager store = StorageManager.builder().build();
            store.getStorage("jdbc").addConnection(NAME, reference::build);

            createPrivateDirectory(preferences.getParent());
            createPrivateDirectory(connections.getParent());
            if (writePreferences) {
                Path temp = privateTemp(preferences.getParent());
                try {
                    TransformerFactory transformerFactory = TransformerFactory.newInstance();
                    transformerFactory.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
                    transformerFactory.setAttribute(XMLConstants.ACCESS_EXTERNAL_STYLESHEET, "");
                    transformerFactory.newTransformer().transform(new DOMSource(doc), new StreamResult(temp.toFile()));
                    Files.createLink(preferences, temp);
                } finally {
                    Files.deleteIfExists(temp);
                }
            }
            Path temp = privateTemp(connections.getParent());
            try {
                store.saveAs(Location.createFileLocation(temp));
                Files.createLink(connections, temp);
            } finally {
                Files.deleteIfExists(temp);
            }
        }
        System.out.println("CONTAINER: created saved connection '" + NAME + "' with encrypted credentials.");
        return true;
    }

    private static void createPrivateDirectory(Path path) throws Exception {
        Files.createDirectories(path, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
    }

    private static Path privateTemp(Path directory) throws Exception {
        return Files.createTempFile(directory, ".connection-setup-", ".tmp",
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
    }
}
