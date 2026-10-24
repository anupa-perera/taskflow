import { defineConfig } from 'vitest/config';

// The CI test stage fails below this.
const MIN_COVERAGE_PERCENT = 70;

export default defineConfig({
  test: {
    include: ['tests/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      // Entry points connect and call process.exit on import; they are verified by running them.
      exclude: [
        'src/server.ts',
        'src/migrate.ts',
        'src/healthcheck.ts',
        'src/migrations/**',
        'src/**/types.ts',
      ],
      reporter: ['text', 'cobertura'],
      thresholds: {
        lines: MIN_COVERAGE_PERCENT,
        statements: MIN_COVERAGE_PERCENT,
        functions: MIN_COVERAGE_PERCENT,
        branches: MIN_COVERAGE_PERCENT,
      },
    },
  },
});
