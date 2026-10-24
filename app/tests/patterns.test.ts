import { describe, expect, it } from 'vitest';
import { patternMessage, PATTERNS } from '../src/patterns.js';

// Same flags Ajv uses for JSON Schema `pattern`.
const matches = (regex: string, value: string) => new RegExp(regex, 'u').test(value);

describe('PATTERNS', () => {
  it.each([
    ['taskflow_app', true],
    ['_role1', true],
    ['a'.repeat(63), true],
    ['a'.repeat(64), false],
    ['1role', false],
    ['TaskFlow', false],
    ['role; DROP', false],
  ])('postgresRoleName %s -> %s', (value, expected) => {
    expect(matches(PATTERNS.postgresRoleName.regex, value)).toBe(expected);
  });

  it.each([
    ['plain text', true],
    ['', true],
    ['a\u0000b', false],
  ])('noNulCharacters %j -> %s', (value, expected) => {
    expect(matches(PATTERNS.noNulCharacters.regex, value)).toBe(expected);
  });

  it.each([
    ['ok', true],
    ['  padded  ', true],
    ['', false],
    ['   ', false],
    [' \u0000', false],
    ['a\u0000b', false],
  ])('notBlankNoNulCharacters %j -> %s', (value, expected) => {
    expect(matches(PATTERNS.notBlankNoNulCharacters.regex, value)).toBe(expected);
  });

  it('rejects a long NUL-terminated title in linear time (no ReDoS)', () => {
    // Linear matching takes ~2 ms here; a quadratic pattern takes minutes. The wide budget
    // keeps a slow CI runner from failing the test while still catching a regression.
    const LINEAR_TIME_BUDGET_MS = 1_000;
    const regex = new RegExp(PATTERNS.notBlankNoNulCharacters.regex, 'u');
    const hostile = `${'a'.repeat(1_000_000)}\u0000`;

    const started = performance.now();
    const accepted = regex.test(hostile);
    const elapsedMs = performance.now() - started;

    expect(accepted).toBe(false);
    expect(elapsedMs).toBeLessThan(LINEAR_TIME_BUDGET_MS);
  });
});

describe('patternMessage', () => {
  it('returns the message for a known pattern and nothing for others', () => {
    expect(patternMessage(PATTERNS.noNulCharacters.regex)).toBe('must not contain NUL characters');
    expect(patternMessage('^x$')).toBeUndefined();
  });
});
