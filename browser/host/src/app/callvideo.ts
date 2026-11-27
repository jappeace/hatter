// A call's video (CallVideoBridge.h): frames drawn into the images that show
// a stream, and the camera's frames, all I420.

import { ImageNode } from './nodes';

/** The camera's frames: this size, or the nearest it has. */
const cameraSize = { width: 640, height: 480 };

/** RGBA pixels as I420, BT.601 limited range as VP8's are. Sides are even. */
function toI420(rgba: Uint8ClampedArray, w: number, h: number): Uint8Array {
  const cw = w >> 1;
  const ch = h >> 1;
  const i420 = new Uint8Array(w * h + 2 * cw * ch);
  for (let i = 0; i < w * h; i++) {
    i420[i] = ((66 * rgba[4 * i] + 129 * rgba[4 * i + 1] + 25 * rgba[4 * i + 2] + 128) >> 8) + 16;
  }
  for (let row = 0; row < ch; row++) {
    for (let col = 0; col < cw; col++) {
      // The mean of the four pixels each chroma sample covers.
      let r = 0;
      let g = 0;
      let b = 0;
      for (const p of [0, 1, w, w + 1]) {
        const at = 4 * (2 * row * w + 2 * col + p);
        r += rgba[at];
        g += rgba[at + 1];
        b += rgba[at + 2];
      }
      r /= 4;
      g /= 4;
      b /= 4;
      i420[w * h + row * cw + col] = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
      i420[w * h + cw * ch + row * cw + col] = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
    }
  }
  return i420;
}

/**
 * The frame a video shows as I420, copied from its planes. Undefined unless
 * the planes are I420 or NV12 in VP8's colours (BT.601, limited range) and
 * not rotated: the caller then draws the frame.
 */
async function planes(video: HTMLVideoElement, w: number, h: number): Promise<Uint8Array | undefined> {
  let frame: VideoFrame | undefined;
  try {
    frame = new VideoFrame(video);
    const { fullRange, matrix } = frame.colorSpace;
    // TypeScript doesn't know these fields yet.
    const { rotation, flip } = frame as VideoFrame & { rotation?: number; flip?: boolean };
    const { x, y, width, height } = frame.visibleRect!;
    if (fullRange !== false || (matrix !== 'smpte170m' && matrix !== 'bt470bg')) return undefined;
    if (rotation || flip || (width & ~1) !== w || (height & ~1) !== h) return undefined;
    const cw = w >> 1;
    const ch = h >> 1;
    const rect = { x, y, width: w, height: h };
    const i420 = new Uint8Array(w * h + 2 * cw * ch);
    switch (frame.format) {
      case 'I420':
        await frame.copyTo(i420, {
          rect,
          layout: [
            { offset: 0, stride: w },
            { offset: w * h, stride: cw },
            { offset: w * h + cw * ch, stride: cw },
          ],
        });
        return i420;
      case 'NV12': {
        // Its chroma comes in pairs, after the luma.
        const nv12 = new Uint8Array(i420.length);
        await frame.copyTo(nv12, {
          rect,
          layout: [
            { offset: 0, stride: w },
            { offset: w * h, stride: 2 * cw },
          ],
        });
        i420.set(nv12.subarray(0, w * h));
        for (let i = 0; i < cw * ch; i++) {
          i420[w * h + i] = nv12[w * h + 2 * i];
          i420[w * h + cw * ch + i] = nv12[w * h + 2 * i + 1];
        }
        return i420;
      }
    }
    return undefined;
  } catch {
    // This browser can't make or copy the frame.
    return undefined;
  } finally {
    frame?.close();
  }
}

export class CallVideo {
  /** The images that show each stream. */
  private readonly watching = new Map<string, Set<ImageNode>>();
  private camera?: MediaStream;
  /** Which start of the camera this is, so a stopped one's late steps do nothing. */
  private filming = 0;

  /** Has an image show a stream's frames. */
  watch(key: string, node: ImageNode): void {
    node.showStream(key);
    let nodes = this.watching.get(key);
    if (!nodes) this.watching.set(key, (nodes = new Set()));
    nodes.add(node);
  }

  show(key: string, width: number, height: number, i420: Uint8Array<ArrayBuffer>): void {
    const nodes = this.watching.get(key);
    if (!nodes) return;
    const frame = new VideoFrame(i420, { format: 'I420', codedWidth: width, codedHeight: height, timestamp: 0 });
    try {
      for (const node of nodes) {
        // Since showing something else.
        if (node.stream !== key) nodes.delete(node);
        else node.draw(frame);
      }
    } finally {
      frame.close();
    }
  }

  /** Passes on the front camera's frames, or the back one's, until stopped. */
  startCamera(front: boolean, deliver: (width: number, height: number, i420: Uint8Array) => void): void {
    this.stopCamera();
    const filming = this.filming;
    this.film(filming, front, deliver).catch((error) => console.warn('Hatter: no camera:', error));
  }

  stopCamera(): void {
    this.filming++;
    this.camera?.getTracks().forEach((track) => track.stop());
    this.camera = undefined;
  }

  private async film(
    filming: number,
    front: boolean,
    deliver: (width: number, height: number, i420: Uint8Array) => void,
  ): Promise<void> {
    const camera = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: front ? 'user' : 'environment', width: { ideal: cameraSize.width }, height: { ideal: cameraSize.height } },
    });
    if (filming !== this.filming) return camera.getTracks().forEach((track) => track.stop());
    this.camera = camera;
    const video = document.createElement('video');
    video.muted = true;
    video.playsInline = true;
    video.srcObject = camera;
    await video.play();
    const canvas = new OffscreenCanvas(1, 1);
    const context = canvas.getContext('2d', { willReadFrequently: true })!;
    /** The video's current frame, drawn and converted. */
    const drawn = (w: number, h: number) => {
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
      }
      context.drawImage(video, 0, 0, w, h);
      return toI420(context.getImageData(0, 0, w, h).data, w, h);
    };
    const each = async () => {
      if (filming !== this.filming) return;
      const w = video.videoWidth & ~1;
      const h = video.videoHeight & ~1;
      if (w > 0 && h > 0) {
        const copied = await planes(video, w, h);
        if (filming !== this.filming) return;
        deliver(w, h, copied ?? drawn(w, h));
      }
      video.requestVideoFrameCallback(each);
    };
    video.requestVideoFrameCallback(each);
  }
}
