package me.jappie.hatter;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.ImageFormat;
import android.hardware.display.DisplayManager;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.util.Size;
import android.view.Display;
import android.view.Surface;
import android.widget.ImageView;
import java.lang.ref.WeakReference;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/**
 * The video of a call, driven from native code on any thread: frames drawn
 * into the image views that show a stream by its key, and the camera's
 * frames, upright, passed to {@link #onFrame}. Frames are I420: the Y
 * plane, then U and V at half the width and height, rounded up.
 */
public final class HatterCallVideo {
    private static final String TAG = "HatterCallVideo";
    /** About the size calls send. */
    private static final int WANTED_WIDTH = 640;
    private static final int WANTED_HEIGHT = 480;
    /** At most this many camera frames a second go to native code. */
    private static final int MAX_FPS = 15;

    private static final Map<String, WeakReference<ImageView>> views =
        Collections.synchronizedMap(new HashMap<>());
    private static final Handler main = new Handler(Looper.getMainLooper());

    private static final Object lock = new Object();
    private static HandlerThread thread;
    private static CameraDevice camera;
    private static ImageReader reader;
    private static long lastFrame;

    private HatterCallVideo() {}

    private static native void onFrame(byte[] i420, int width, int height);

    /** The view now showing the stream, from the renderer on the UI thread. */
    public static void attach(byte[] key, ImageView view) {
        views.put(new String(key, StandardCharsets.UTF_8), new WeakReference<>(view));
    }

    public static void show(byte[] key, int width, int height, byte[] i420) {
        WeakReference<ImageView> shown = views.get(new String(key, StandardCharsets.UTF_8));
        if (shown == null || shown.get() == null) {
            return;
        }
        final Bitmap bitmap = toBitmap(width, height, i420);
        main.post(() -> {
            ImageView view = shown.get();
            if (view != null) {
                view.setImageBitmap(bitmap);
            }
        });
    }

    private static Bitmap toBitmap(int width, int height, byte[] i420) {
        int[] argb = new int[width * height];
        int chromaWidth = (width + 1) / 2;
        int uStart = width * height;
        int vStart = uStart + chromaWidth * ((height + 1) / 2);
        for (int y = 0; y < height; y++) {
            int chromaRow = (y / 2) * chromaWidth;
            for (int x = 0; x < width; x++) {
                int luma = (i420[y * width + x] & 0xff) - 16;
                int u = (i420[uStart + chromaRow + x / 2] & 0xff) - 128;
                int v = (i420[vStart + chromaRow + x / 2] & 0xff) - 128;
                int c = 298 * Math.max(luma, 0);
                int r = clamp((c + 409 * v + 128) >> 8);
                int g = clamp((c - 100 * u - 208 * v + 128) >> 8);
                int b = clamp((c + 516 * u + 128) >> 8);
                argb[y * width + x] = 0xff000000 | (r << 16) | (g << 8) | b;
            }
        }
        return Bitmap.createBitmap(argb, width, height, Bitmap.Config.ARGB_8888);
    }

    private static int clamp(int value) {
        return value < 0 ? 0 : Math.min(value, 255);
    }

    public static void startCamera(Context context, boolean front) {
        synchronized (lock) {
            stopCamera();
            CameraManager manager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
            try {
                String id = null;
                CameraCharacteristics characteristics = null;
                int facing = front ? CameraCharacteristics.LENS_FACING_FRONT : CameraCharacteristics.LENS_FACING_BACK;
                for (String candidate : manager.getCameraIdList()) {
                    CameraCharacteristics c = manager.getCameraCharacteristics(candidate);
                    Integer lens = c.get(CameraCharacteristics.LENS_FACING);
                    if (id == null || (lens != null && lens == facing)) {
                        id = candidate;
                        characteristics = c;
                        if (lens != null && lens == facing) {
                            break;
                        }
                    }
                }
                if (id == null) {
                    Log.e(TAG, "No camera");
                    return;
                }
                Integer sensor = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION);
                final int sensorDegrees = sensor == null ? 0 : sensor;
                final boolean facingFront = front;
                final Display display = ((DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE))
                    .getDisplay(Display.DEFAULT_DISPLAY);
                Size size = closestSize(characteristics);
                thread = new HandlerThread("HatterCallVideo camera");
                thread.start();
                final Handler handler = new Handler(thread.getLooper());
                reader = ImageReader.newInstance(size.getWidth(), size.getHeight(), ImageFormat.YUV_420_888, 3);
                reader.setOnImageAvailableListener(r -> {
                    Image image = r.acquireLatestImage();
                    if (image == null) {
                        return;
                    }
                    long now = SystemClock.elapsedRealtime();
                    if (now - lastFrame >= 1000 / MAX_FPS) {
                        lastFrame = now;
                        deliver(image, upright(sensorDegrees, facingFront, display));
                    }
                    image.close();
                }, handler);
                final ImageReader target = reader;
                manager.openCamera(id, new CameraDevice.StateCallback() {
                    @Override
                    public void onOpened(CameraDevice device) {
                        synchronized (lock) {
                            if (reader != target) {
                                device.close();
                                return;
                            }
                            camera = device;
                        }
                        capture(device, target, handler);
                    }

                    @Override
                    public void onDisconnected(CameraDevice device) {
                        device.close();
                    }

                    @Override
                    public void onError(CameraDevice device, int error) {
                        Log.e(TAG, "Camera error " + error);
                        device.close();
                    }
                }, handler);
            } catch (CameraAccessException | SecurityException | IllegalArgumentException e) {
                Log.e(TAG, "The camera didn't open: " + e.getMessage());
            }
        }
    }

    public static void stopCamera() {
        synchronized (lock) {
            if (camera != null) {
                camera.close();
                camera = null;
            }
            if (thread != null) {
                thread.quitSafely();
                try {
                    thread.join(1000);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
                thread = null;
            }
            // After the thread, as closing the reader frees images the
            // thread may still be reading.
            if (reader != null) {
                reader.close();
                reader = null;
            }
        }
    }

    @SuppressWarnings("deprecation")
    private static void capture(CameraDevice device, ImageReader target, Handler handler) {
        try {
            device.createCaptureSession(Collections.singletonList(target.getSurface()),
                new CameraCaptureSession.StateCallback() {
                    @Override
                    public void onConfigured(CameraCaptureSession session) {
                        try {
                            CaptureRequest.Builder request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD);
                            request.addTarget(target.getSurface());
                            session.setRepeatingRequest(request.build(), null, handler);
                        } catch (CameraAccessException | IllegalStateException e) {
                            Log.e(TAG, "Capture failed: " + e.getMessage());
                        }
                    }

                    @Override
                    public void onConfigureFailed(CameraCaptureSession session) {
                        Log.e(TAG, "Capture session failed");
                    }
                }, handler);
        } catch (CameraAccessException | IllegalStateException e) {
            Log.e(TAG, "Capture session failed: " + e.getMessage());
        }
    }

    /**
     * How far to turn the camera's image clockwise for it to be upright as
     * the device is held now, as Camera2 documents for JPEG orientation.
     */
    private static int upright(int sensorDegrees, boolean front, Display display) {
        int device = 0;
        switch (display == null ? Surface.ROTATION_0 : display.getRotation()) {
            case Surface.ROTATION_90:
                device = 90;
                break;
            case Surface.ROTATION_180:
                device = 180;
                break;
            case Surface.ROTATION_270:
                device = 270;
                break;
            default:
                break;
        }
        return front ? (sensorDegrees + device) % 360 : (sensorDegrees - device + 360) % 360;
    }

    /** The YUV size nearest to the one calls send, by how many pixels it has. */
    private static Size closestSize(CameraCharacteristics characteristics) {
        StreamConfigurationMap map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
        Size best = new Size(WANTED_WIDTH, WANTED_HEIGHT);
        if (map == null) {
            return best;
        }
        long wanted = (long) WANTED_WIDTH * WANTED_HEIGHT;
        long bestDistance = Long.MAX_VALUE;
        for (Size size : map.getOutputSizes(ImageFormat.YUV_420_888)) {
            long distance = Math.abs((long) size.getWidth() * size.getHeight() - wanted);
            if (distance < bestDistance) {
                best = size;
                bestDistance = distance;
            }
        }
        return best;
    }

    /** The image as I420, turned clockwise by the rotation. */
    private static void deliver(Image image, int rotation) {
        int width = image.getWidth() & ~1;
        int height = image.getHeight() & ~1;
        boolean sideways = rotation == 90 || rotation == 270;
        int outWidth = sideways ? height : width;
        int outHeight = sideways ? width : height;
        byte[] i420 = new byte[outWidth * outHeight * 3 / 2];
        Image.Plane[] planes = image.getPlanes();
        turn(planes[0], width, height, rotation, i420, 0, outWidth, outHeight);
        int chroma = outWidth * outHeight;
        turn(planes[1], width / 2, height / 2, rotation, i420, chroma, outWidth / 2, outHeight / 2);
        turn(planes[2], width / 2, height / 2, rotation, i420, chroma + chroma / 4, outWidth / 2, outHeight / 2);
        onFrame(i420, outWidth, outHeight);
    }

    private static void turn(Image.Plane plane, int width, int height, int rotation,
                             byte[] out, int start, int outWidth, int outHeight) {
        ByteBuffer buffer = plane.getBuffer();
        int rowStride = plane.getRowStride();
        int pixelStride = plane.getPixelStride();
        for (int oy = 0; oy < outHeight; oy++) {
            for (int ox = 0; ox < outWidth; ox++) {
                int sx;
                int sy;
                switch (rotation) {
                    case 90:
                        sx = oy;
                        sy = height - 1 - ox;
                        break;
                    case 180:
                        sx = width - 1 - ox;
                        sy = height - 1 - oy;
                        break;
                    case 270:
                        sx = width - 1 - oy;
                        sy = ox;
                        break;
                    default:
                        sx = ox;
                        sy = oy;
                        break;
                }
                out[start + oy * outWidth + ox] = buffer.get(sy * rowStride + sx * pixelStride);
            }
        }
    }
}
