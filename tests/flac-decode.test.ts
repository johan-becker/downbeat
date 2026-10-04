import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { FLACDecoder } from "@wasm-audio-decoders/flac";

/**
 * Lossless mode is two implementations that never meet except on the wire:
 * Apple's FLAC encoder in the CLI and libFLAC-in-WASM in the browser. The
 * fixture is real CLI output (`downbeat selftest lossless --dump
 * tests/fixtures/flac-sine.bin`), so this is the one place the pair is proven
 * to agree bit for bit -- regenerate it whenever the encoder settings change.
 */

/** Mirror of `losslessTestSignal` in cli/Sources/downbeat/SelfTest.swift. */
function losslessTestSignal(frames: number): Int32Array {
  const out = new Int32Array(frames * 2);
  let x = 1;
  for (let i = 0; i < frames; i++) {
    const phase = i % 400;
    out[2 * i] = (phase < 200 ? phase : 400 - phase) * 41_943 - 4_194_300;
    x = (Math.imul(x, 1_103_515_245) + 12_345) & 0x7fffffff;
    out[2 * i + 1] = (x >>> 8) - 4_194_304;
  }
  return out;
}

function readPackets(path: string): Uint8Array[] {
  const buf = readFileSync(path);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const count = view.getUint32(0, true);
  const packets: Uint8Array[] = [];
  let at = 4;
  for (let i = 0; i < count; i++) {
    const len = view.getUint32(at, true);
    packets.push(new Uint8Array(buf.buffer, buf.byteOffset + at + 4, len));
    at += 4 + len;
  }
  return packets;
}

describe("lossless wire format", () => {
  const packets = readPackets(new URL("./fixtures/flac-sine.bin", import.meta.url).pathname);

  it("is 20 ms FLAC frames that stand alone", () => {
    expect(packets).toHaveLength(25);
    for (const p of packets) {
      // FLAC frame sync, fixed block size: decodable without any stream header.
      expect(p[0]).toBe(0xff);
      expect(p[1] & 0xfe).toBe(0xf8);
    }
  });

  it("decodes packet by packet, bit-exact, in the browser's decoder", async () => {
    const decoder = new FLACDecoder();
    await decoder.ready;
    const expected = losslessTestSignal(960 * packets.length);
    let mismatches = 0;
    try {
      for (let n = 0; n < packets.length; n++) {
        // One packet per call, exactly as LivePlayer feeds them off the socket.
        const out = await decoder.decodeFrames([packets[n]]);
        expect(out.errors).toHaveLength(0);
        expect(out.samplesDecoded).toBe(960);
        expect(out.sampleRate).toBe(48_000);
        expect(out.bitDepth).toBe(24);
        for (let i = 0; i < 960; i++) {
          for (let c = 0; c < 2; c++) {
            // libFLAC-in-WASM scales by 2^23 - 1, not 2^23 (the encoder's
            // side): a 0.000001 dB level difference, but the inverse is needed
            // to get the integers back and compare them exactly.
            const got = Math.round(out.channelData[c][i] * 8_388_607);
            if (got !== expected[2 * (n * 960 + i) + c]) mismatches++;
          }
        }
      }
    } finally {
      decoder.free();
    }
    expect(mismatches).toBe(0);
  });
});
