/**
 * WebCodecs timestamps are MICROSECONDS, and Chrome takes that literally.
 *
 * Feeding the stream's sample index in as the chunk timestamp works in
 * Safari, which hands each chunk's timestamp straight back on its output. Chrome
 * does not: it keeps the FIRST input timestamp as a base and stamps every
 * later output base + decoded duration in microseconds -- +20000 per 20 ms
 * packet where the ring expects +960. Read back as samples, the write head then
 * runs 20.8x real time, the read head never sees a sample land in its window,
 * and the device renders pure silence with a "cushion" of minutes. Speak the
 * unit the API speaks and convert at both edges.
 */

export function sampleToMicros(sampleIndex: number, sampleRate: number): number {
  return Math.round((sampleIndex * 1_000_000) / sampleRate);
}

/** Exact while the decoder's own rounding stays under half a sample (~10 us). */
export function microsToSample(micros: number, sampleRate: number): number {
  return Math.round((micros * sampleRate) / 1_000_000);
}
