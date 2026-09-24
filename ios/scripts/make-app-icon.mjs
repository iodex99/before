#!/usr/bin/env node
/**
 * Generates the BEFORE app icon: a 1024×1024 PNG, no dependencies.
 *
 * The concept (spec §60) is a single strong letter B on the warm off-white
 * background, in the burgundy accent. No tiny text, nothing that dissolves at
 * 40pt on a home screen.
 *
 * This is a placeholder a designer should replace — but it is a REAL asset, so
 * the project builds and ships a legible icon today rather than a missing file.
 *
 *   node ios/scripts/make-app-icon.mjs
 */

import { deflateSync } from 'node:zlib';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SIZE = 1024;
const SS = 3; // supersample factor, for smooth curves

const BACKGROUND = [0xfa, 0xf8, 0xf5]; // warm off-white
const INK = [0x6e, 0x26, 0x39]; // burgundy accent

// --- The letterform, in icon coordinates -----------------------------------
//
// Derived rather than eyeballed, so the counters close cleanly and the glyph is
// optically centred:
//
//   Each bowl's INNER radius is exactly half its counter height, which makes the
//   inner curve meet the bars tangentially instead of leaving a notch. The outer
//   radius is inner + STROKE, so the bowl spans precisely from the outer edge of
//   one bar to the outer edge of the next.
//
//   The lower bowl is larger than the upper, as in any real B.

const STROKE = 85;
const TOP = 202;
const BOTTOM = 822; // 620 tall, centred in 1024
const LEFT = 323;

const UPPER_COUNTER = { y0: TOP + STROKE, y1: 437 }; // 150 tall
const LOWER_COUNTER = { y0: 522, y1: BOTTOM - STROKE }; // 215 tall

const UPPER_BOWL = {
  cx: LEFT + 180,
  cy: (UPPER_COUNTER.y0 + UPPER_COUNTER.y1) / 2,
  inner: (UPPER_COUNTER.y1 - UPPER_COUNTER.y0) / 2,
  outer: (UPPER_COUNTER.y1 - UPPER_COUNTER.y0) / 2 + STROKE,
};

const LOWER_BOWL = {
  cx: LEFT + 185,
  cy: (LOWER_COUNTER.y0 + LOWER_COUNTER.y1) / 2,
  inner: (LOWER_COUNTER.y1 - LOWER_COUNTER.y0) / 2,
  outer: (LOWER_COUNTER.y1 - LOWER_COUNTER.y0) / 2 + STROKE,
};

const STEM = { x0: LEFT, x1: LEFT + STROKE, y0: TOP, y1: BOTTOM };
const TOP_BAR = { x0: LEFT, x1: UPPER_BOWL.cx, y0: TOP, y1: TOP + STROKE };
const MIDDLE_BAR = { x0: LEFT, x1: LOWER_BOWL.cx, y0: UPPER_COUNTER.y1, y1: LOWER_COUNTER.y0 };
const BOTTOM_BAR = { x0: LEFT, x1: LOWER_BOWL.cx, y0: BOTTOM - STROKE, y1: BOTTOM };

const inRect = (x, y, r) => x >= r.x0 && x <= r.x1 && y >= r.y0 && y <= r.y1;

function inHalfRing(x, y, ring) {
  if (x < ring.cx) return false; // right half only
  const dx = x - ring.cx;
  const dy = y - ring.cy;
  const distance = Math.sqrt(dx * dx + dy * dy);
  return distance <= ring.outer && distance >= ring.inner;
}

function isInk(x, y) {
  return (
    inRect(x, y, STEM) ||
    inRect(x, y, TOP_BAR) ||
    inRect(x, y, MIDDLE_BAR) ||
    inRect(x, y, BOTTOM_BAR) ||
    inHalfRing(x, y, UPPER_BOWL) ||
    inHalfRing(x, y, LOWER_BOWL)
  );
}

// --- Rasterise with supersampled anti-aliasing ------------------------------

const raw = Buffer.alloc(SIZE * (SIZE * 3 + 1));

for (let y = 0; y < SIZE; y++) {
  const rowStart = y * (SIZE * 3 + 1);
  raw[rowStart] = 0; // PNG filter type: none

  for (let x = 0; x < SIZE; x++) {
    let hits = 0;
    for (let sy = 0; sy < SS; sy++) {
      for (let sx = 0; sx < SS; sx++) {
        if (isInk(x + (sx + 0.5) / SS, y + (sy + 0.5) / SS)) hits++;
      }
    }

    const coverage = hits / (SS * SS);
    const offset = rowStart + 1 + x * 3;
    for (let channel = 0; channel < 3; channel++) {
      raw[offset + channel] = Math.round(
        BACKGROUND[channel] * (1 - coverage) + INK[channel] * coverage,
      );
    }
  }
}

// --- PNG container ----------------------------------------------------------

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const typeAndData = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(typeAndData));
  return Buffer.concat([length, typeAndData, crc]);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(SIZE, 0);
ihdr.writeUInt32BE(SIZE, 4);
ihdr[8] = 8; // bit depth
ihdr[9] = 2; // colour type: truecolour
ihdr[10] = 0; // deflate
ihdr[11] = 0; // adaptive filtering
ihdr[12] = 0; // no interlace

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);

const here = dirname(fileURLToPath(import.meta.url));
const target = join(here, '../BEFORE/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png');
mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, png);

console.log(`Wrote ${target} (${SIZE}×${SIZE}, ${(png.length / 1024).toFixed(1)} KB)`);
