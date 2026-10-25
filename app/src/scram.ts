import { createHash, createHmac, pbkdf2Sync, randomBytes } from 'node:crypto';

// PostgreSQL's own defaults for SCRAM-SHA-256 (RFC 7677).
const ITERATIONS = 4096;
const SALT_BYTES = 16;
const KEY_BYTES = 32;

const hmac = (key: Buffer, message: string) => createHmac('sha256', key).update(message).digest();

/**
 * Builds the verifier PostgreSQL stores for a SCRAM-SHA-256 password, so `ALTER ROLE ... PASSWORD`
 * can be sent the verifier instead of the plaintext: a logged statement then reveals no password.
 * Passwords are assumed ASCII; SASLprep normalisation is not applied.
 */
export function scramSha256Verifier(password: string, salt = randomBytes(SALT_BYTES)): string {
  const saltedPassword = pbkdf2Sync(password, salt, ITERATIONS, KEY_BYTES, 'sha256');
  const storedKey = createHash('sha256').update(hmac(saltedPassword, 'Client Key')).digest();
  const serverKey = hmac(saltedPassword, 'Server Key');
  return `SCRAM-SHA-256$${String(ITERATIONS)}:${salt.toString('base64')}$${storedKey.toString('base64')}:${serverKey.toString('base64')}`;
}
