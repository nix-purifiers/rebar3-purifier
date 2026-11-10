import java.net.*;
import java.nio.file.*;
import java.security.*;
import java.util.*;
public class Resources {
  public static void main(String[] args) throws Exception {
    Path jar = Path.of(args[0]).toRealPath();
    try (URLClassLoader loader = new URLClassLoader(new URL[]{jar.toUri().toURL()}, null)) {
      int count = 0;
      for (String line : Files.readAllLines(Path.of(args[1]))) {
        String[] row = line.split("\t"); URL url = loader.getResource(row[0]);
        if (url == null || !url.getProtocol().equals("jar")) throw new AssertionError(row[0]);
        JarURLConnection connection = (JarURLConnection) url.openConnection();
        if (!Path.of(connection.getJarFileURL().toURI()).toRealPath().equals(jar)) throw new AssertionError("origin");
        try (var stream = url.openStream()) {
          String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(stream.readAllBytes()));
          if (!digest.equals(row[1])) throw new AssertionError("bytes");
        }
        count++;
      }
      if (loader.getResource("catalog.json") != null) throw new AssertionError("proof metadata exported");
      System.out.println("Exact native OTP resource bytes/origins: " + count);
    }
  }
}
