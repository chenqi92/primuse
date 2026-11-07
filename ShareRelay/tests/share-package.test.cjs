const test = require('node:test');
const assert = require('node:assert/strict');
const { validatedManifest } = require('../web/share.js');
const media = {
  version: 1, fileName: 'audio.mp3', contentType: 'audio/mpeg', size: 2048,
  chunkSize: 4194304, title: 'Night Signal', audioFormat: 'MP3', durationSeconds: 15,
};

test('legacy audio manifest remains playable', () => {
  const parsed = validatedManifest(media, media.size, media.chunkSize);
  assert.equal(parsed.title, media.title);
  assert.equal(parsed.packageSummary, null);
});

test('small configuration packages can be previewed', () => {
  const input = { ...media, fileName: 'Primuse.primuseshare', contentType: 'application/vnd.primuse.share',
    size: 320, durationSeconds: 0, packageSummary: ['Night Signal', 'My settings'] };
  assert.deepEqual(validatedManifest(input, 320, input.chunkSize).packageSummary, input.packageSummary);
});

test('package metadata cannot impersonate audio or provide arbitrary objects', () => {
  const input = { ...media, contentType: 'application/vnd.primuse.share', packageSummary: ['Radio'] };
  assert.throws(() => validatedManifest(input, input.size, input.chunkSize));
  input.fileName = 'Primuse.primuseshare';
  for (const summary of [null, [{ html: '<script>' }], Array(9).fill('station'), ['x'.repeat(161)]]) {
    assert.throws(() => validatedManifest({ ...input, packageSummary: summary }, input.size, input.chunkSize));
  }
});

test('integrity mismatches and invalid versions are rejected', () => {
  for (const change of [{ size: 0 }, { version: 2 }, { chunkSize: 1 }, { size: 2049 }, { durationSeconds: Infinity }]) {
    assert.throws(() => validatedManifest({ ...media, ...change }, media.size, media.chunkSize));
  }
});
