package me.jappie.hatter;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.util.DisplayMetrics;
import android.webkit.MimeTypeMap;
import android.widget.Toast;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Files for native code: picking one, showing one in another app, and
 * decoding a picture no larger than the screen needs.
 */
public final class HatterFiles {
    private HatterFiles() {}

    /** The provider's authority, which apps declare in their manifest. */
    static String authority(Context context) {
        return context.getPackageName() + ".files";
    }

    static Intent pickIntent(String mimeType) {
        return new Intent(Intent.ACTION_GET_CONTENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mimeType);
    }

    /** A picked file, copied where native code can read it, and its own name. */
    static final class Picked {
        final File file;
        final String name;

        Picked(File file, String name) {
            this.file = file;
            this.name = name;
        }
    }

    /** Copy what the user picked into the cache. Slow, so not on the UI thread. */
    static Picked copyPicked(Context context, Uri uri) throws IOException {
        ContentResolver resolver = context.getContentResolver();
        String name = "file";
        try (Cursor cursor = resolver.query(uri, new String[] {OpenableColumns.DISPLAY_NAME},
                                            null, null, null)) {
            if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) {
                name = new File(cursor.getString(0)).getName();
            }
        }
        File dir = new File(new File(context.getCacheDir(), "picked"),
                            Long.toString(System.nanoTime()));
        if (!dir.mkdirs()) {
            throw new IOException("Cannot make " + dir);
        }
        // Paths stay ASCII, for native code that doesn't know the encoding.
        File file = new File(dir, name.replaceAll("[^A-Za-z0-9._-]", "_"));
        try (InputStream in = resolver.openInputStream(uri);
             OutputStream out = new FileOutputStream(file)) {
            if (in == null) {
                throw new IOException("Cannot read " + uri);
            }
            byte[] buffer = new byte[64 * 1024];
            for (int n; (n = in.read(buffer)) > 0;) {
                out.write(buffer, 0, n);
            }
        }
        return new Picked(file, name);
    }

    /** Show one of the app's files in an app that takes its type. */
    static void open(Activity activity, String path) {
        File file = new File(path);
        if (!HatterFileProvider.isServed(activity, file)) {
            return;
        }
        Uri uri = new Uri.Builder()
            .scheme(ContentResolver.SCHEME_CONTENT)
            .authority(authority(activity))
            .path(file.getAbsolutePath())
            .build();
        Intent intent = new Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mimeType(file.getName()))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try {
            activity.startActivity(intent);
        } catch (ActivityNotFoundException e) {
            Toast.makeText(activity, "No app opens this file", Toast.LENGTH_SHORT).show();
        }
    }

    static String mimeType(String name) {
        int dot = name.lastIndexOf('.');
        String type = dot < 0 ? null
            : MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substring(dot + 1).toLowerCase());
        return type != null ? type : "application/octet-stream";
    }

    /** A picture file's width and height, turned the way its camera says, or null. */
    static int[] size(String path) {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(path, bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            return null;
        }
        int degrees = 0;
        try {
            int orientation = new ExifInterface(path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
            if (orientation == ExifInterface.ORIENTATION_ROTATE_90
                    || orientation == ExifInterface.ORIENTATION_ROTATE_270) {
                degrees = 90;
            }
        } catch (IOException e) {
            // Not a picture with EXIF data: as it is.
        }
        return degrees == 90 ? new int[] {bounds.outHeight, bounds.outWidth}
                             : new int[] {bounds.outWidth, bounds.outHeight};
    }

    /** A picture from bytes, as {@link #decode} one from a file, as it is turned. */
    static Bitmap decodeBytes(Context context, byte[] data) {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(data, 0, data.length, bounds);
        BitmapFactory.Options options = sampled(context, bounds);
        Bitmap bitmap = options == null ? null : BitmapFactory.decodeByteArray(data, 0, data.length, options);
        if (bitmap == null) {
            return null;
        }
        try {
            return turned(new ExifInterface(new java.io.ByteArrayInputStream(data)), bitmap);
        } catch (IOException e) {
            return bitmap;
        }
    }

    /**
     * How to decode a picture of these bounds: halved while its long side
     * stays as long as the screen's. Null if it isn't one or has more than
     * {@link #MAX_PIXELS}.
     */
    private static BitmapFactory.Options sampled(Context context, BitmapFactory.Options bounds) {
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0
                || (long) bounds.outWidth * bounds.outHeight > MAX_PIXELS) {
            return null;
        }
        DisplayMetrics screen = context.getResources().getDisplayMetrics();
        int longest = Math.max(screen.widthPixels, screen.heightPixels);
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = 1;
        while (Math.max(bounds.outWidth, bounds.outHeight) / (options.inSampleSize * 2) >= longest) {
            options.inSampleSize *= 2;
        }
        return options;
    }

    /**
     * A picked picture cut to its middle square and scaled to the first of
     * the sides whose PNG has at most limit bytes, turned the way its camera
     * says. Null if it isn't one, is too large, or none fits.
     */
    static byte[] squarePng(Context context, Uri uri, int[] sides, int limit) {
        // Copied to a file once: read into memory, a RAW photo runs the app
        // out of it, and each open of a cloud picture may download it.
        Bitmap picture;
        try {
            File copy = copyPicked(context, uri).file;
            try {
                picture = decode(context, copy.getPath());
            } finally {
                copy.delete();
                copy.getParentFile().delete();
            }
        } catch (IOException | SecurityException e) {
            android.util.Log.w("HatterPicture", "Couldn't copy or decode the picture", e);
            return null;
        }
        if (picture == null) {
            android.util.Log.w("HatterPicture", "The picture didn't decode");
            return null;
        }
        int square = Math.min(picture.getWidth(), picture.getHeight());
        Bitmap middle = Bitmap.createBitmap(picture, (picture.getWidth() - square) / 2,
                                            (picture.getHeight() - square) / 2, square, square);
        for (int side : sides) {
            Bitmap scaled = Bitmap.createScaledBitmap(middle, side, side, true);
            java.io.ByteArrayOutputStream png = new java.io.ByteArrayOutputStream();
            scaled.compress(Bitmap.CompressFormat.PNG, 100, png);
            if (png.size() <= limit) {
                return png.toByteArray();
            }
        }
        android.util.Log.w("HatterPicture", "No side gave a PNG of at most " + limit + " bytes");
        return null;
    }

    /**
     * From native code: width and height, big-endian, then RGBA pixels not
     * premultiplied, turned the way the camera says and halved until there
     * are at most so many, or null if the file is no picture.
     */
    static byte[] pixels(byte[] path, int maxPixels) {
        String file = new String(path, java.nio.charset.StandardCharsets.UTF_8);
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(file, options);
        if (options.outWidth <= 0 || options.outHeight <= 0) {
            return null;
        }
        int sample = 1;
        while ((long) (options.outWidth / sample) * (options.outHeight / sample) > maxPixels) {
            sample *= 2;
        }
        options = new BitmapFactory.Options();
        options.inSampleSize = sample;
        options.inPreferredConfig = Bitmap.Config.ARGB_8888;
        Bitmap bitmap = BitmapFactory.decodeFile(file, options);
        if (bitmap == null) {
            return null;
        }
        bitmap = turned(file, bitmap);
        int width = bitmap.getWidth();
        int height = bitmap.getHeight();
        int[] argb = new int[width * height];
        bitmap.getPixels(argb, 0, width, 0, 0, width, height);
        byte[] out = new byte[8 + argb.length * 4];
        java.nio.ByteBuffer.wrap(out).putInt(width).putInt(height);
        for (int i = 0; i < argb.length; i++) {
            int p = argb[i];
            out[8 + i * 4] = (byte) (p >> 16);
            out[9 + i * 4] = (byte) (p >> 8);
            out[10 + i * 4] = (byte) p;
            out[11 + i * 4] = (byte) (p >>> 24);
        }
        return out;
    }

    /**
     * From native code: a picture written again to out, turned the way its
     * camera says, no longer than longest on either side and without its
     * metadata. 1 as JPEG, 2 as PNG for one with transparency, 0 if the
     * file is no picture or can't be written.
     */
    static int shrink(byte[] path, byte[] out, int longest) {
        String file = new String(path, java.nio.charset.StandardCharsets.UTF_8);
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(file, options);
        if (options.outWidth <= 0 || options.outHeight <= 0) {
            return 0;
        }
        int sample = 1;
        while (Math.max(options.outWidth, options.outHeight) / (sample * 2) >= longest) {
            sample *= 2;
        }
        options = new BitmapFactory.Options();
        options.inSampleSize = sample;
        Bitmap bitmap = BitmapFactory.decodeFile(file, options);
        if (bitmap == null) {
            return 0;
        }
        bitmap = turned(file, bitmap);
        int side = Math.max(bitmap.getWidth(), bitmap.getHeight());
        if (side > longest) {
            bitmap = Bitmap.createScaledBitmap(bitmap, bitmap.getWidth() * longest / side,
                                               bitmap.getHeight() * longest / side, true);
        }
        boolean clear = bitmap.hasAlpha();
        File written = new File(new String(out, java.nio.charset.StandardCharsets.UTF_8));
        boolean done;
        try (java.io.FileOutputStream stream = new java.io.FileOutputStream(written)) {
            done = bitmap.compress(clear ? Bitmap.CompressFormat.PNG : Bitmap.CompressFormat.JPEG, 85, stream);
        } catch (IOException e) {
            done = false;
        }
        if (!done) {
            // Don't leave half a picture behind.
            written.delete();
            return 0;
        }
        return clear ? 2 : 1;
    }

    /** Pictures with more pixels take too long to decode, however small they are shown. */
    private static final long MAX_PIXELS = 1L << 26;

    /**
     * A picture from a file, halved while its long side stays as long as
     * the screen's, and turned the way its camera says. Null if it isn't
     * one or has more than {@link #MAX_PIXELS}.
     */
    static Bitmap decode(Context context, String path) {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(path, bounds);
        BitmapFactory.Options options = sampled(context, bounds);
        if (options == null) {
            return null;
        }
        Bitmap bitmap = BitmapFactory.decodeFile(path, options);
        if (bitmap == null) {
            return null;
        }
        return turned(path, bitmap);
    }

    /** As its camera says it was held. */
    private static Bitmap turned(String path, Bitmap bitmap) {
        try {
            return turned(new ExifInterface(path), bitmap);
        } catch (IOException e) {
            // Not a picture with EXIF data: as it is.
            return bitmap;
        }
    }

    private static Bitmap turned(ExifInterface exif, Bitmap bitmap) {
        int degrees;
        switch (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            case ExifInterface.ORIENTATION_ROTATE_90: degrees = 90; break;
            case ExifInterface.ORIENTATION_ROTATE_180: degrees = 180; break;
            case ExifInterface.ORIENTATION_ROTATE_270: degrees = 270; break;
            default: degrees = 0; break;
        }
        if (degrees == 0) {
            return bitmap;
        }
        Matrix turn = new Matrix();
        turn.postRotate(degrees);
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), turn, true);
    }
}
