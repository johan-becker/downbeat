import { describe, expect, it } from "vitest";
import { microsToSample, sampleToMicros } from "../src/audio/timestamps";

describe("WebCodecs timestamp conversion", () => {
  it("survives Chrome re-deriving outputs from the first timestamp plus duration", () => {
    // Chrome keeps only the first chunk's timestamp and adds decoded duration
    // in microseconds to it. Every output must still map to its exact sample.
    for (const rate of [48000, 44100]) {
      for (const first of [0, 1, 123_456_789, 3_000_000_001]) {
        const base = sampleToMicros(first, rate);
        for (let k = 0; k < 5000; k++) {
          const chromeOut = base + Math.round((k * 960 * 1_000_000) / rate);
          expect(microsToSample(chromeOut, rate)).toBe(first + k * 960);
        }
      }
    }
  });
});
