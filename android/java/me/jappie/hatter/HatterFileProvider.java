package me.jappie.hatter;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;

/**
 * Lets other apps read the app's files that it shows them, read only, by
 * content URIs of their absolute paths, and the camera app write the one
 * picture it is asked to take. Apps declare it in their manifest, with the
 * authority of their package name and ".files", not exported and granting
 * URI permissions.
 */
public final class HatterFileProvider extends ContentProvider {
    /** Only files in the app's files and cache directories. */
    static boolean isServed(Context context, File file) {
        try {
            String path = file.getCanonicalPath();
            return path.startsWith(context.getFilesDir().getCanonicalPath() + File.separator)
                || path.startsWith(context.getCacheDir().getCanonicalPath() + File.separator);
        } catch (IOException e) {
            return false;
        }
    }

    private File served(Uri uri) throws FileNotFoundException {
        File file = new File(uri.getPath());
        if (!isServed(getContext(), file) || !file.isFile()) {
            throw new FileNotFoundException(uri.toString());
        }
        return file;
    }

    @Override
    public boolean onCreate() {
        return true;
    }

    /** Where the camera app may write. */
    static File captureDir(Context context) {
        return new File(context.getCacheDir(), "capture");
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (mode.contains("w")) {
            File file = new File(uri.getPath());
            try {
                File dir = captureDir(getContext()).getCanonicalFile();
                if (!dir.equals(file.getCanonicalFile().getParentFile())) {
                    throw new FileNotFoundException(uri.toString());
                }
            } catch (IOException e) {
                throw new FileNotFoundException(uri.toString());
            }
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.parseMode(mode));
        }
        return ParcelFileDescriptor.open(served(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override
    public String getType(Uri uri) {
        return HatterFiles.mimeType(new File(uri.getPath()).getName());
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs,
                        String sortOrder) {
        File file;
        try {
            file = served(uri);
        } catch (FileNotFoundException e) {
            return null;
        }
        MatrixCursor cursor = new MatrixCursor(
            new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
        cursor.addRow(new Object[] {file.getName(), file.length()});
        return cursor;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException("Read only");
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException("Read only");
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException("Read only");
    }
}
