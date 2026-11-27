package me.jappie.hatter;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioFocusRequest;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTimestamp;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.AudioEffect;
import android.media.audiofx.NoiseSuppressor;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.TimeUnit;

/**
 * The audio of a call, driven from native code on any thread: the
 * microphone in frames, passed to {@link #onFrame}, and the other side's
 * audio played, both in voice call mode, with the platform's echo
 * cancellation. Other audio pauses while it goes, and while another call
 * (such as a phone call) has the audio, the microphone sends silence.
 * A headset that connects takes the call, and the screen goes dark near the
 * ear while the earpiece plays it, which needs the app to declare
 * android.permission.WAKE_LOCK.
 */
public final class HatterCallAudio {
    private static final String TAG = "HatterCallAudio";
    /** Frames waiting to be played beyond this many are dropped, oldest first. */
    private static final int MAX_QUEUED = 10;

    private static final Object lock = new Object();
    private static AudioRecord record;
    private static Thread recorder;
    private static Thread player;
    private static volatile boolean running;
    private static final List<AudioEffect> effects = new ArrayList<>();
    private static AudioFocusRequest focus;
    /** Whether something else has the audio. */
    private static volatile boolean held;
    private static final LinkedBlockingDeque<Frame> queue = new LinkedBlockingDeque<>();
    private static volatile AudioTrack track;
    private static volatile int trackRate;
    private static volatile long written;

    /** Where the audio goes, as CallAudioBridge.h numbers them. */
    private static final int EARPIECE = 0;
    private static final int SPEAKER = 1;
    private static final int WIRED = 2;
    private static final int BLUETOOTH = 3;
    /** Without a headset, whether the loudspeaker plays the call. */
    private static boolean speakerFirst;
    /** The route the user chose, until a headset connects, or -1. */
    private static int chosen = -1;
    /** What {@link #onRoutes} was last told, so it hears only of changes. */
    private static int toldRoute = -1;
    private static int toldAvailable;
    private static AudioDeviceCallback devices;
    private static PowerManager.WakeLock proximity;

    /** Told when call audio starts and stops, on the thread that did it. */
    public interface Listener {
        void onCallAudio(Context context, boolean running);
    }

    private static volatile Listener listener;

    private HatterCallAudio() {}

    /**
     * For an app's foreground service, which needs the microphone type for
     * the call to go on in the background.
     */
    public static void setListener(Listener newListener) {
        listener = newListener;
    }

    private static void tell(Context context, boolean running) {
        Listener current = listener;
        if (current != null) {
            current.onCallAudio(context, running);
        }
    }

    private static final class Frame {
        final int rate;
        final int channels;
        final short[] pcm;

        Frame(int rate, int channels, short[] pcm) {
            this.rate = rate;
            this.channels = channels;
            this.pcm = pcm;
        }
    }

    private static native void onFrame(short[] pcm, int count);

    private static native void onRoutes(int route, int available);

    public static void start(Context context, int rate, int frameSamples, boolean speaker) {
        synchronized (lock) {
            stop(context);
            AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
            audio.setMode(AudioManager.MODE_IN_COMMUNICATION);
            held = false;
            focus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(voice())
                .setOnAudioFocusChangeListener(change -> {
                    if (change == AudioManager.AUDIOFOCUS_GAIN) {
                        held = false;
                    } else if (change == AudioManager.AUDIOFOCUS_LOSS
                               || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                        held = true;
                    }
                })
                .build();
            audio.requestAudioFocus(focus);
            running = true;
            tell(context, true);
            startRouting(context, audio, speaker);
            player = new Thread(HatterCallAudio::playLoop, "HatterCallAudio player");
            player.start();
            try {
                int minimum = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT);
                record = new AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, rate,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                    Math.max(minimum, frameSamples * 2 * 4));
            } catch (SecurityException e) {
                Log.e(TAG, "No microphone permission: " + e.getMessage());
                return;
            }
            if (record.getState() != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "The microphone didn't open");
                record.release();
                record = null;
                return;
            }
            if (AcousticEchoCanceler.isAvailable()) {
                AcousticEchoCanceler canceler = AcousticEchoCanceler.create(record.getAudioSessionId());
                if (canceler != null) {
                    canceler.setEnabled(true);
                    effects.add(canceler);
                }
            }
            if (NoiseSuppressor.isAvailable()) {
                NoiseSuppressor suppressor = NoiseSuppressor.create(record.getAudioSessionId());
                if (suppressor != null) {
                    suppressor.setEnabled(true);
                    effects.add(suppressor);
                }
            }
            final AudioRecord recording = record;
            recorder = new Thread(() -> recordLoop(recording, frameSamples), "HatterCallAudio recorder");
            recording.startRecording();
            recorder.start();
        }
    }

    public static void stop(Context context) {
        synchronized (lock) {
            if (!running) {
                return;
            }
            running = false;
            join(recorder);
            join(player);
            recorder = null;
            player = null;
            for (AudioEffect effect : effects) {
                effect.release();
            }
            effects.clear();
            if (record != null) {
                record.stop();
                record.release();
                record = null;
            }
            queue.clear();
            AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
            audio.unregisterAudioDeviceCallback(devices);
            devices = null;
            if (proximity != null) {
                if (proximity.isHeld()) {
                    proximity.release();
                }
                proximity = null;
            }
            if (focus != null) {
                audio.abandonAudioFocusRequest(focus);
                focus = null;
            }
            if (Build.VERSION.SDK_INT >= 31) {
                audio.clearCommunicationDevice();
            } else {
                audio.setSpeakerphoneOn(false);
            }
            audio.setMode(AudioManager.MODE_NORMAL);
            tell(context, false);
        }
    }

    /** Interleaved samples. Returns the milliseconds of audio waiting to be played, these included. */
    public static int play(int rate, int channels, short[] pcm) {
        if (!running) {
            return 0;
        }
        queue.offerLast(new Frame(rate, channels, pcm));
        while (queue.size() > MAX_QUEUED) {
            queue.pollFirst();
        }
        long millis = 0;
        for (Frame frame : queue) {
            millis += 1000L * frame.pcm.length / ((long) frame.rate * frame.channels);
        }
        AudioTrack playing = track;
        int playingRate = trackRate;
        if (playing != null && playingRate > 0) {
            millis += Math.max(0, (written - (playing.getPlaybackHeadPosition() & 0xffffffffL)) * 1000 / playingRate);
        }
        return (int) millis;
    }

    /** How long after the track plays audio it's heard, by its timestamps: 0 until it has one. */
    public static int latency() {
        AudioTrack playing = track;
        int rate = trackRate;
        AudioTimestamp stamp = new AudioTimestamp();
        if (playing == null || rate == 0 || !playing.getTimestamp(stamp)) {
            return 0;
        }
        long heard = stamp.framePosition + (System.nanoTime() - stamp.nanoTime) * rate / 1000000000L;
        return (int) Math.max(0, ((playing.getPlaybackHeadPosition() & 0xffffffffL) - heard) * 1000 / rate);
    }

    private static android.media.Ringtone ringtone;
    private static android.media.ToneGenerator ringback;
    private static android.os.Vibrator vibrator;

    /** 0 nothing, 1 the ringtone of a call coming in, 2 the ring-back of one going out. */
    public static void tone(Context context, int tone) {
        synchronized (lock) {
            if (ringtone != null) {
                ringtone.stop();
                ringtone = null;
            }
            if (ringback != null) {
                ringback.stopTone();
                ringback.release();
                ringback = null;
            }
            if (vibrator != null) {
                vibrator.cancel();
                vibrator = null;
            }
            AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
            if (tone == 1) {
                ringtone = android.media.RingtoneManager.getRingtone(context,
                    android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE));
                if (ringtone != null) {
                    ringtone.setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build());
                    if (Build.VERSION.SDK_INT >= 28) {
                        ringtone.setLooping(true);
                    }
                    ringtone.play();
                }
                if (audio.getRingerMode() != AudioManager.RINGER_MODE_SILENT) {
                    vibrator = context.getSystemService(android.os.Vibrator.class);
                    vibrator.vibrate(android.os.VibrationEffect.createWaveform(new long[] {0, 800, 800}, 0));
                }
            } else if (tone == 2) {
                ringback = new android.media.ToneGenerator(AudioManager.STREAM_VOICE_CALL, 80);
                ringback.startTone(android.media.ToneGenerator.TONE_SUP_RINGTONE);
            }
        }
    }

    /** The route the user chooses, while it is there or until a headset connects. */
    public static void route(Context context, int route) {
        synchronized (lock) {
            if (!running) {
                return;
            }
            chosen = route;
            applyRoute(context);
        }
    }

    private static void startRouting(Context context, AudioManager audio, boolean speaker) {
        speakerFirst = speaker;
        chosen = -1;
        toldRoute = -1;
        PowerManager power = context.getSystemService(PowerManager.class);
        if (power.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
            proximity = power.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "hatter:call");
        }
        devices = new AudioDeviceCallback() {
            @Override
            public void onAudioDevicesAdded(AudioDeviceInfo[] added) {
                synchronized (lock) {
                    if (!running) {
                        return;
                    }
                    // As phones do, a headset connecting takes the call.
                    for (AudioDeviceInfo device : added) {
                        int route = routeOf(device.getType());
                        if (route == WIRED || route == BLUETOOTH) {
                            chosen = -1;
                        }
                    }
                    applyRoute(context);
                }
            }

            @Override
            public void onAudioDevicesRemoved(AudioDeviceInfo[] removed) {
                synchronized (lock) {
                    if (running) {
                        applyRoute(context);
                    }
                }
            }
        };
        audio.registerAudioDeviceCallback(devices, new Handler(Looper.getMainLooper()));
        applyRoute(context);
    }

    private static void applyRoute(Context context) {
        AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        Map<Integer, AudioDeviceInfo> there = available(audio);
        int route = SPEAKER;
        if (chosen >= 0 && there.containsKey(chosen)) {
            route = chosen;
        } else {
            for (int r : new int[] {BLUETOOTH, WIRED, speakerFirst ? SPEAKER : EARPIECE}) {
                if (there.containsKey(r)) {
                    route = r;
                    break;
                }
            }
        }
        if (Build.VERSION.SDK_INT >= 31) {
            AudioDeviceInfo device = there.get(route);
            if (device != null) {
                audio.setCommunicationDevice(device);
            }
        } else {
            audio.setSpeakerphoneOn(route == SPEAKER);
        }
        if (proximity != null) {
            try {
                if (route == EARPIECE && !proximity.isHeld()) {
                    proximity.acquire();
                } else if (route != EARPIECE && proximity.isHeld()) {
                    proximity.release();
                }
            } catch (SecurityException e) {
                Log.e(TAG, "No WAKE_LOCK permission, so the screen stays on at the ear");
                proximity = null;
            }
        }
        int mask = 0;
        for (int r : there.keySet()) {
            mask |= 1 << r;
        }
        if (route != toldRoute || mask != toldAvailable) {
            toldRoute = route;
            toldAvailable = mask;
            onRoutes(route, mask);
        }
    }

    /**
     * The routes there are, each with a device to choose. Before Android 12
     * only the earpiece and the loudspeaker, with no device: a wired headset
     * takes the place of the earpiece by itself.
     */
    private static Map<Integer, AudioDeviceInfo> available(AudioManager audio) {
        Map<Integer, AudioDeviceInfo> there = new LinkedHashMap<>();
        if (Build.VERSION.SDK_INT >= 31) {
            for (AudioDeviceInfo device : audio.getAvailableCommunicationDevices()) {
                int route = routeOf(device.getType());
                if (route >= 0 && !there.containsKey(route)) {
                    there.put(route, device);
                }
            }
        } else {
            there.put(EARPIECE, null);
            there.put(SPEAKER, null);
        }
        return there;
    }

    private static int routeOf(int type) {
        switch (type) {
            case AudioDeviceInfo.TYPE_BUILTIN_EARPIECE:
                return EARPIECE;
            case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:
                return SPEAKER;
            case AudioDeviceInfo.TYPE_WIRED_HEADSET:
            case AudioDeviceInfo.TYPE_WIRED_HEADPHONES:
            case AudioDeviceInfo.TYPE_USB_HEADSET:
                return WIRED;
            case AudioDeviceInfo.TYPE_BLUETOOTH_SCO:
            case AudioDeviceInfo.TYPE_BLE_HEADSET:
            case AudioDeviceInfo.TYPE_HEARING_AID:
                return BLUETOOTH;
            default:
                return -1;
        }
    }

    private static void recordLoop(AudioRecord recording, int frameSamples) {
        short[] frame = new short[frameSamples];
        while (running) {
            int read = recording.read(frame, 0, frameSamples);
            if (read == frameSamples) {
                if (held) {
                    Arrays.fill(frame, (short) 0);
                }
                onFrame(frame, read);
            } else if (read < 0) {
                Log.e(TAG, "Recording failed: " + read);
                return;
            }
        }
    }

    /** Plays frames as they come: the app decides when they're due. */
    private static void playLoop() {
        int channels = 0;
        try {
            while (running) {
                Frame frame = queue.pollFirst(100, TimeUnit.MILLISECONDS);
                if (frame == null) {
                    continue;
                }
                if (track == null || frame.rate != trackRate || frame.channels != channels) {
                    if (track != null) {
                        track.release();
                    }
                    channels = frame.channels;
                    written = 0;
                    trackRate = frame.rate;
                    track = newTrack(trackRate, channels);
                    track.play();
                }
                // Counted before the write, which waits for room: the frame
                // has left the queue, and play must still count it.
                written += frame.pcm.length / channels;
                track.write(frame.pcm, 0, frame.pcm.length);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } finally {
            if (track != null) {
                track.release();
                track = null;
            }
        }
    }

    private static AudioTrack newTrack(int rate, int channels) {
        int mask = channels == 2 ? AudioFormat.CHANNEL_OUT_STEREO : AudioFormat.CHANNEL_OUT_MONO;
        int minimum = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT);
        return new AudioTrack.Builder()
            .setAudioAttributes(voice())
            .setAudioFormat(new AudioFormat.Builder()
                .setSampleRate(rate)
                .setChannelMask(mask)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build())
            .setBufferSizeInBytes(minimum)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build();
    }

    private static AudioAttributes voice() {
        return new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build();
    }

    private static void join(Thread thread) {
        if (thread == null) {
            return;
        }
        try {
            thread.join(1000);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
