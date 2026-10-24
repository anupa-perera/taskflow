import { describe, expect, it } from 'vitest';
import { scramSha256Verifier } from '../src/scram.js';

// Produced by PostgreSQL 17 itself: CREATE ROLE ... PASSWORD 'pencil', then read from pg_authid.
const POSTGRES_VERIFIER =
  'SCRAM-SHA-256$4096:/YBgcQITletKySAlZpNKkw==$qlvHD0aPJ1y8JNg53PbvKlTDBz5SMb0okeHsDA4Px4w=:LDL8lndchUo/G5Cy70SUJfOmzYst5JJcJn2TnuLkhB4=';

describe('scramSha256Verifier', () => {
  it('matches the verifier PostgreSQL computes for the same password and salt', () => {
    const salt = Buffer.from('/YBgcQITletKySAlZpNKkw==', 'base64');

    expect(scramSha256Verifier('pencil', salt)).toBe(POSTGRES_VERIFIER);
  });

  it('salts each verifier differently and never contains the password', () => {
    const first = scramSha256Verifier('pencil');
    const second = scramSha256Verifier('pencil');

    expect(first).not.toBe(second);
    expect(first).not.toContain('pencil');
  });
});
