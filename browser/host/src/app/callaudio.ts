// A call's audio (CallAudioBridge.h): the other side's played as it comes,
// and the microphone recorded in frames, with the browser's echo
// cancellation. Also the tones a phone plays around calls.

/** Passes on what the microphone records, a block at a time. */
const recorder = `
registerProcessor('hatter-recorder', class extends AudioWorkletProcessor {
  process([input]) {
    if (input.length > 0) this.port.postMessage(input[0].slice());
    return true;
  }
});`;

/** CallAudioBridge.h's tones. */
const enum Tone {
  Quiet = 0,
  Ringtone = 1,
  Ringback = 2,
}

/** Each tone's notes, in Hz and seconds, played in turn and again from the start. */
const tones: Record<number, [number, number][]> = {
  // Two rising notes, and a pause.
  [Tone.Ringtone]: [
    [659, 0.4],
    [880, 0.4],
    [0, 2],
  ],
  // A second of 425 Hz in every five, as most of Europe rings back.
  [Tone.Ringback]: [
    [425, 1],
    [0, 4],
  ],
};

/** How loud tones are, of the loudest there is. */
const toneVolume = 0.2;

const sample = (x: number) => Math.max(-32768, Math.min(32767, Math.round(x * 32768)));

export class CallAudio {
  private context?: AudioContext;
  /** When what's been played ends, on the context's clock. */
  private end = 0;
  private microphone?: MediaStream;
  /** Which call's audio this is, so a stopped one's late steps do nothing. */
  private call = 0;
  private toneContext?: AudioContext;

  /** Plays the other side's audio from now on, and records frames of the microphone for it. */
  start(rate: number, frameSamples: number, deliver: (frame: Int16Array) => void): void {
    this.stop();
    const call = ++this.call;
    const context = new AudioContext({ sampleRate: rate, latencyHint: 'interactive' });
    this.context = context;
    this.end = 0;
    void context.resume();
    this.record(call, context, frameSamples, deliver).catch((error) => console.warn('Hatter: no microphone:', error));
  }

  stop(): void {
    this.call++;
    this.microphone?.getTracks().forEach((track) => track.stop());
    this.microphone = undefined;
    void this.context?.close();
    this.context = undefined;
  }

  /** Interleaved samples, played after the last. Returns the milliseconds of audio waiting to play. */
  play(rate: number, channels: number, samples: Int16Array): number {
    const context = this.context;
    if (!context || samples.length < channels) return 0;
    const frames = Math.floor(samples.length / channels);
    const buffer = context.createBuffer(channels, frames, rate);
    for (let c = 0; c < channels; c++) {
      const out = buffer.getChannelData(c);
      for (let i = 0; i < frames; i++) out[i] = samples[i * channels + c] / 32768;
    }
    const source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(context.destination);
    // After a gap, from now.
    this.end = Math.max(this.end, context.currentTime);
    source.start(this.end);
    this.end += buffer.duration;
    return Math.round((this.end - context.currentTime) * 1000);
  }

  /** Milliseconds from playing audio to it being heard. */
  latency(): number {
    const context = this.context;
    return context ? Math.round(((context.outputLatency || 0) + context.baseLatency) * 1000) : 0;
  }

  /** Plays a tone, over and over, in place of the last. */
  tone(tone: number): void {
    void this.toneContext?.close();
    this.toneContext = undefined;
    const notes = tones[tone];
    if (!notes) return;
    const context = new AudioContext();
    this.toneContext = context;
    const rate = context.sampleRate;
    const cycle = context.createBuffer(1, Math.round(notes.reduce((sum, [, seconds]) => sum + seconds, 0) * rate), rate);
    const out = cycle.getChannelData(0);
    let at = 0;
    for (const [hz, seconds] of notes) {
      const length = Math.round(seconds * rate);
      // Each note fades in and out over 10 ms, so it doesn't click.
      const fade = Math.min(length / 2, rate / 100);
      for (let i = 0; hz > 0 && i < length && at + i < out.length; i++) {
        out[at + i] = toneVolume * Math.sin((2 * Math.PI * hz * i) / rate) * Math.min(1, i / fade, (length - i) / fade);
      }
      at += length;
    }
    const source = context.createBufferSource();
    source.buffer = cycle;
    source.loop = true;
    source.connect(context.destination);
    source.start();
  }

  private async record(call: number, context: AudioContext, frameSamples: number, deliver: (frame: Int16Array) => void): Promise<void> {
    const microphone = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
    if (call !== this.call) return microphone.getTracks().forEach((track) => track.stop());
    this.microphone = microphone;
    const url = URL.createObjectURL(new Blob([recorder], { type: 'text/javascript' }));
    try {
      await context.audioWorklet.addModule(url);
    } finally {
      URL.revokeObjectURL(url);
    }
    if (call !== this.call) return;
    const node = new AudioWorkletNode(context, 'hatter-recorder', { numberOfOutputs: 0 });
    const frame = new Int16Array(frameSamples);
    let filled = 0;
    node.port.onmessage = ({ data }: MessageEvent<Float32Array>) => {
      for (const x of data) {
        frame[filled++] = sample(x);
        if (filled === frameSamples) {
          deliver(frame.slice());
          filled = 0;
        }
      }
    };
    context.createMediaStreamSource(microphone).connect(node);
  }
}
