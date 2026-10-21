// Shared test helpers. Real-data tests run only when the repository's data.pak exists
// (it is git-ignored); everything else uses synthetic fixtures with no game data.
import { existsSync } from 'node:fs';
import { DEFAULT_PAK, openPak, type Pak } from '../pak.ts';
export const hasPak = existsSync(DEFAULT_PAK);
let shared: Pak | undefined;
export const pak = () => (shared ??= openPak());
