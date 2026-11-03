package me.jappie.hatter;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.file.Files;
import java.security.KeyStore;
import java.security.SecureRandom;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * The app's key for its database: random, kept in the files directory
 * encrypted with a key that never leaves the Android keystore.
 */
public final class HatterDatabaseKey {
    private static final String TAG = "HatterDatabaseKey";
    private static final String ALIAS = "hatter_database_key";
    private static final String FILE = "database.key";
    private static final int KEY_BYTES = 32;
    private static final int IV_BYTES = 12;
    private static final int TAG_BITS = 128;

    private HatterDatabaseKey() {
    }

    /** The key, made the first time, or null if the keystore failed. */
    public static byte[] get(Context context) {
        try {
            SecretKey wrapping = wrappingKey();
            File file = new File(context.getFilesDir(), FILE);
            if (file.exists()) {
                byte[] kept = Files.readAllBytes(file.toPath());
                Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.DECRYPT_MODE, wrapping,
                    new GCMParameterSpec(TAG_BITS, kept, 0, IV_BYTES));
                return cipher.doFinal(kept, IV_BYTES, kept.length - IV_BYTES);
            }
            byte[] key = new byte[KEY_BYTES];
            new SecureRandom().nextBytes(key);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, wrapping);
            byte[] iv = cipher.getIV();
            byte[] sealed = cipher.doFinal(key);
            // Written whole or not at all, as a key half written loses the
            // database.
            File partial = new File(context.getFilesDir(), FILE + ".new");
            try (FileOutputStream out = new FileOutputStream(partial)) {
                out.write(iv);
                out.write(sealed);
                out.getFD().sync();
            }
            if (!partial.renameTo(file)) {
                throw new java.io.IOException("Could not keep " + file);
            }
            return key;
        } catch (Exception e) {
            Log.e(TAG, "No database key", e);
            return null;
        }
    }

    private static SecretKey wrappingKey() throws Exception {
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        if (!keyStore.containsAlias(ALIAS)) {
            KeyGenerator generator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
            generator.generateKey();
        }
        return (SecretKey) keyStore.getKey(ALIAS, null);
    }
}
