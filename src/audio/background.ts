/**
 * Keep Chrome on Android playing while the user is in another app.
 *
 * Chrome only counts a tab as playing media -- the thing that earns it a
 * media notification and keeps its process alive behind another app -- when
 * an HTMLMediaElement is playing. Web Audio does not count: switch apps and
 * the tab is frozen within seconds, socket and all, while Safari carries on.
 *
 * So, alongside the real output, an <audio> element loops silence. Only the
 * keepalive goes through the element; the music stays on the AudioContext,
 * so latency and sync calibration are exactly what they were. The clip must
 * outlast Chrome's ~5 s floor for "real" media: shorter players are treated
 * as one-shot sounds and get neither the notification nor the keepalive.
 */

const SILENCE_SECONDS = 10;
const SILENCE_RATE = 8000;

export function needsBackgroundKeepalive(): boolean {
  return /Android/i.test(navigator.userAgent);
}

/** 8-bit mono PCM WAV of pure silence (0x80 is the 8-bit midpoint). */
function silentWav(): Blob {
  const frames = SILENCE_SECONDS * SILENCE_RATE;
  const buf = new ArrayBuffer(44 + frames);
  const v = new DataView(buf);
  const ascii = (at: number, s: string) => {
    for (let i = 0; i < s.length; i++) v.setUint8(at + i, s.charCodeAt(i));
  };
  ascii(0, "RIFF");
  v.setUint32(4, 36 + frames, true);
  ascii(8, "WAVE");
  ascii(12, "fmt ");
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true); // PCM
  v.setUint16(22, 1, true); // mono
  v.setUint32(24, SILENCE_RATE, true);
  v.setUint32(28, SILENCE_RATE, true); // byte rate
  v.setUint16(32, 1, true); // block align
  v.setUint16(34, 8, true); // bits per sample
  ascii(36, "data");
  v.setUint32(40, frames, true);
  new Uint8Array(buf, 44).fill(0x80);
  return new Blob([buf], { type: "audio/wav" });
}

export class BackgroundKeepalive {
  private el: HTMLAudioElement | null = null;
  private url: string | null = null;

  constructor(
    private readonly title: string,
    private readonly onPause: () => void,
    private readonly onPlay: () => void,
  ) {}

  /** Call inside the join tap: play() needs the gesture. Idempotent. */
  start(): void {
    if (!this.el) {
      this.url = URL.createObjectURL(silentWav());
      const el = new Audio(this.url);
      el.loop = true;
      this.el = el;
      this.registerSession();
    }
    void this.el.play().catch(() => {
      /* no gesture yet; the next tap (join, tap-to-fix) retries */
    });
    this.setState("playing");
  }

  stop(): void {
    this.el?.pause();
    this.el = null;
    if (this.url) URL.revokeObjectURL(this.url);
    this.url = null;
    const ms = navigator.mediaSession;
    if (ms) {
      ms.metadata = null;
      ms.playbackState = "none";
      for (const a of ["play", "pause", "stop"] as const) {
        try {
          ms.setActionHandler(a, null);
        } catch {
          /* unsupported action */
        }
      }
    }
  }

  private registerSession(): void {
    const ms = navigator.mediaSession;
    if (!ms) return;
    ms.metadata = new MediaMetadata({ title: this.title, artist: "Downbeat" });
    const handle = (a: MediaSessionAction, fn: () => void) => {
      try {
        ms.setActionHandler(a, fn);
      } catch {
        /* unsupported action */
      }
    };
    // The notification's pause must actually silence the speaker, or it
    // reads as broken; play brings it back and the clock re-locks itself.
    handle("pause", () => {
      this.el?.pause();
      this.setState("paused");
      this.onPause();
    });
    handle("play", () => {
      void this.el?.play().catch(() => {});
      this.setState("playing");
      this.onPlay();
    });
  }

  private setState(s: MediaSessionPlaybackState): void {
    if (navigator.mediaSession) navigator.mediaSession.playbackState = s;
  }
}
