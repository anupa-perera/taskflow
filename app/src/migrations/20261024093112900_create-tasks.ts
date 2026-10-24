import type { MigrationBuilder } from 'node-pg-migrate';

export function up(pgm: MigrationBuilder): void {
  pgm.createTable('tasks', {
    id: { type: 'uuid', primaryKey: true, default: pgm.func('gen_random_uuid()') },
    title: { type: 'varchar(200)', notNull: true },
    description: { type: 'varchar(2000)' },
    // Not a Postgres ENUM: ENUM values cannot be removed or reordered.
    status: {
      type: 'text',
      notNull: true,
      default: 'todo',
      check: "status IN ('todo', 'in_progress', 'done')",
    },
    created_at: { type: 'timestamptz', notNull: true, default: pgm.func('now()') },
    updated_at: { type: 'timestamptz', notNull: true, default: pgm.func('now()') },
  });
  // Match the list query's ORDER BY, with and without the status filter.
  pgm.createIndex('tasks', [
    'status',
    { name: 'created_at', sort: 'DESC' },
    { name: 'id', sort: 'DESC' },
  ]);
  pgm.createIndex('tasks', [
    { name: 'created_at', sort: 'DESC' },
    { name: 'id', sort: 'DESC' },
  ]);
}

export function down(pgm: MigrationBuilder): void {
  pgm.dropTable('tasks');
}
