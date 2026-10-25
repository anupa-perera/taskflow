// Each regex is paired with the message clients see, since Ajv's default would echo the regex.
export const PATTERNS = {
  // Unquoted Postgres identifier: at most 63 bytes, lowercase so it never needs quoting.
  postgresRoleName: {
    regex: '^[a-z_][a-z0-9_]{0,62}$',
    message: 'must be a lowercase Postgres identifier of at most 63 characters',
  },
  // PostgreSQL text cannot store NUL (\u0000); reject it as a 400, not a database error.
  noNulCharacters: {
    regex: '^[^\\u0000]*$',
    message: 'must not contain NUL characters',
  },
  // The three parts match disjoint characters, so evaluation stays linear (no ReDoS).
  notBlankNoNulCharacters: {
    regex: '^\\s*[^\\s\\u0000][^\\u0000]*$',
    message: 'must not be blank or contain NUL characters',
  },
  // The SCRAM verifier is computed without SASLprep, which only leaves ASCII passwords unchanged.
  printableAscii: {
    regex: '^[\\x20-\\x7E]+$',
    message: 'must contain only printable ASCII characters',
  },
} as const;

const messageByRegex = new Map<string, string>(
  Object.values(PATTERNS).map(({ regex, message }) => [regex, message]),
);

export const patternMessage = (regex: string): string | undefined => messageByRegex.get(regex);
