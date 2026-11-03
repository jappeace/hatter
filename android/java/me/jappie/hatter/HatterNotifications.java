package me.jappie.hatter;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Person;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.os.Build;
import java.nio.charset.StandardCharsets;

/**
 * Notifications shown from native code, from any thread, with the
 * Application's context. Tapping one opens the app's launcher activity
 * with the notification's key in {@link #EXTRA_KEY}. A ringing one has
 * buttons to answer, which opens the app with {@link #EXTRA_ANSWER} too,
 * and to decline, which {@link Declined} takes without opening it.
 */
public final class HatterNotifications {
    public static final String EXTRA_KEY = "me.jappie.hatter.notification";
    public static final String EXTRA_ANSWER = "me.jappie.hatter.answer";
    static final int ANSWER = 0;
    static final int DECLINE = 1;
    static final int END = 2;

    /** Told when the call going on changes, for an app's foreground service. */
    public interface OngoingListener {
        void onOngoingCall(Context context);
    }

    private static volatile OngoingListener ongoingListener;
    private static volatile String ongoingKey;
    private static volatile String ongoingTitle;
    private static volatile long ongoingSince;

    public static void setOngoingListener(OngoingListener listener) {
        ongoingListener = listener;
    }

    private static volatile String status = "";

    /**
     * What the app's background service says it is doing, as its
     * notification shows it, which the ongoing listener is told of.
     */
    public static void setStatus(Context context, byte[] text) {
        status = new String(text, StandardCharsets.UTF_8);
        OngoingListener current = ongoingListener;
        if (current != null) {
            current.onOngoingCall(context);
        }
    }

    public static String status() {
        return status;
    }

    /** Told when the app is to stop running in the background. */
    public interface StopListener {
        void onStop(Context context);
    }

    private static volatile StopListener stopListener;

    /** For an app's foreground service, which stops itself and its process. */
    public static void setStopListener(StopListener listener) {
        stopListener = listener;
    }

    /** Whether the app runs in the background, kept for when the phone starts. */
    public static void runInBackground(Context context, boolean on) {
        context.getSharedPreferences("hatter", Context.MODE_PRIVATE).edit()
            .putBoolean("background", on).apply();
    }

    /** For an app's boot receiver, which runs without Haskell. */
    public static boolean runsInBackground(Context context) {
        return context.getSharedPreferences("hatter", Context.MODE_PRIVATE).getBoolean("background", true);
    }

    public static void stopBackground(Context context) {
        StopListener current = stopListener;
        if (current != null) {
            current.onStop(context);
        }
    }

    /** Whether the activity shows over the lock screen and turns the screen on. */
    public static void overLockScreen(Context context, boolean on) {
        HatterActivity.setOverLockScreen(on);
    }

    /** Whether the screen stays on while the activity shows. */
    public static void keepScreenOn(Context context, boolean on) {
        HatterActivity.setKeepScreenOn(on);
    }

    /**
     * Whether a call may ring over the lock screen, which the user may
     * forbid from Android 14 on.
     */
    public static boolean fullScreenAllowed(Context context) {
        if (Build.VERSION.SDK_INT < 34) {
            return true;
        }
        return context.getSystemService(NotificationManager.class).canUseFullScreenIntent();
    }

    /** Where the user lets calls ring over the lock screen. */
    public static void allowFullScreen(Context context) {
        if (Build.VERSION.SDK_INT < 34) {
            return;
        }
        Intent intent = new Intent(android.provider.Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
            android.net.Uri.parse("package:" + context.getPackageName()));
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        context.startActivity(intent);
    }

    /** From native code, which passes UTF-8: an empty title is no call. */
    public static void setOngoing(Context context, byte[] key, byte[] title, long since) {
        ongoingKey = utf8(key);
        ongoingTitle = title.length == 0 ? null : utf8(title);
        ongoingSince = since;
        OngoingListener listener = ongoingListener;
        if (listener != null) {
            listener.onOngoingCall(context);
        }
    }

    /**
     * The notification of the call going on, with its time and a hang-up
     * button, for a foreground service to show, or null without one.
     */
    public static Notification ongoingCall(Context context, String channel, int icon, PendingIntent open) {
        String title = ongoingTitle;
        if (title == null) {
            return null;
        }
        Intent ending = new Intent(context, HungUp.class).putExtra(EXTRA_KEY, ongoingKey);
        PendingIntent hangUp = PendingIntent.getBroadcast(context, 0, ending,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder builder = new Notification.Builder(context, channel)
            .setSmallIcon(icon)
            .setContentTitle(title)
            .setContentIntent(open)
            .setOngoing(true)
            .setUsesChronometer(true)
            .setWhen(ongoingSince)
            .setCategory(Notification.CATEGORY_CALL);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setStyle(Notification.CallStyle.forOngoingCall(
                new Person.Builder().setName(title).build(), hangUp));
        } else {
            builder.addAction(new Notification.Action.Builder(null, "Hang up", hangUp).build());
        }
        return builder.build();
    }

    /** Hangs up the call going on from its notification. */
    public static final class HungUp extends android.content.BroadcastReceiver {
        @Override
        public void onReceive(Context context, Intent intent) {
            String key = intent.getStringExtra(EXTRA_KEY);
            if (key != null) {
                pressed(key, END);
            }
        }
    }

    private HatterNotifications() {}

    /** From native code, which passes UTF-8. */
    public static void show(Context context, byte[] key, byte[] channel, byte[] icon,
                            byte[] title, byte[] text, int kind) {
        show(context, utf8(key), utf8(channel), utf8(icon), utf8(title), utf8(text), kind);
    }

    public static void cancel(Context context, byte[] key) {
        cancel(context, utf8(key));
    }

    private static String utf8(byte[] bytes) {
        return new String(bytes, StandardCharsets.UTF_8);
    }

    /** To native code, which takes the key in UTF-8. */
    static native void onCallButton(byte[] key, int button);

    static void pressed(String key, int button) {
        onCallButton(key.getBytes(StandardCharsets.UTF_8), button);
    }

    /** As native code's NOTIFICATION_* kinds. */
    static final int MESSAGE = 0;
    static final int RINGING_CALL = 1;
    static final int MISSED_CALL = 2;

    /** A ringing one is a call, whose channel plays the ringtone until it is cancelled or tapped. */
    public static void show(Context context, String key, String channel, String icon,
                            String title, String text, int kind) {
        boolean ringing = kind == RINGING_CALL;
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        NotificationChannel made = new NotificationChannel(channel, channel, NotificationManager.IMPORTANCE_HIGH);
        if (ringing) {
            made.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build());
        }
        manager.createNotificationChannel(made);
        Intent open = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        open.putExtra(EXTRA_KEY, key);
        // Each key its own request code, or the extras of one replace another's.
        PendingIntent tap = PendingIntent.getActivity(context, key.hashCode(), open,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        String latest = text.substring(text.lastIndexOf('\n') + 1);
        Notification.Builder builder = new Notification.Builder(context, channel)
            .setSmallIcon(context.getResources().getIdentifier(icon, "drawable", context.getPackageName()))
            .setContentTitle(title)
            .setContentText(latest)
            .setStyle(new Notification.BigTextStyle().bigText(text))
            .setCategory(ringing ? Notification.CATEGORY_CALL
                : kind == MISSED_CALL ? Notification.CATEGORY_MISSED_CALL : Notification.CATEGORY_MESSAGE)
            // Grouped by channel, so Android doesn't bundle them with the app's others.
            .setGroup(channel)
            .setContentIntent(tap)
            .setAutoCancel(true);
        if (ringing) {
            ringing(context, builder, key, open, title, tap);
        }
        Notification notification = builder.build();
        if (ringing) {
            notification.flags |= Notification.FLAG_INSISTENT;
        }
        manager.notify(key, 0, notification);
    }

    /** A call's buttons, and its screen over another app's or a dark one's. */
    private static void ringing(Context context, Notification.Builder builder, String key, Intent open,
                                String title, PendingIntent tap) {
        Intent answering = new Intent(open).putExtra(EXTRA_ANSWER, true);
        PendingIntent answer = PendingIntent.getActivity(context, key.hashCode() + 1, answering,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Intent declining = new Intent(context, Declined.class).putExtra(EXTRA_KEY, key);
        PendingIntent decline = PendingIntent.getBroadcast(context, key.hashCode(), declining,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        builder.setFullScreenIntent(tap, true).setOngoing(true);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setStyle(Notification.CallStyle.forIncomingCall(
                new Person.Builder().setName(title).build(), decline, answer));
        } else {
            builder.addAction(new Notification.Action.Builder(null, "Decline", decline).build())
                .addAction(new Notification.Action.Builder(null, "Answer", answer).build());
        }
    }

    /** Declines a call from its notification. */
    public static final class Declined extends android.content.BroadcastReceiver {
        @Override
        public void onReceive(Context context, Intent intent) {
            String key = intent.getStringExtra(EXTRA_KEY);
            if (key != null) {
                cancel(context, key);
                pressed(key, DECLINE);
            }
        }
    }

    public static void cancel(Context context, String key) {
        context.getSystemService(NotificationManager.class).cancel(key, 0);
    }
}
