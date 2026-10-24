import type pg from 'pg';
import type { CreateTaskBody, Task, TaskStatus, UpdateTaskBody } from './types.js';

export interface ListOptions {
  status?: TaskStatus | undefined;
  limit: number;
  offset: number;
}

interface TaskRow {
  id: string;
  title: string;
  description: string | null;
  status: TaskStatus;
  created_at: Date;
  updated_at: Date;
}

const COLUMNS = 'id, title, description, status, created_at, updated_at';

// Allow-list for dynamic UPDATEs: only these column names can reach the SQL text.
const UPDATABLE_COLUMNS = {
  title: 'title',
  description: 'description',
  status: 'status',
} as const satisfies Record<keyof UpdateTaskBody, string>;

// $1 is the task id, so the changed columns' placeholders start at $2.
const FIRST_CHANGE_PLACEHOLDER = 2;

function toTask(row: TaskRow): Task {
  return {
    id: row.id,
    title: row.title,
    description: row.description,
    status: row.status,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
  };
}

export interface TaskRepository {
  create(input: CreateTaskBody): Promise<Task>;
  list(options: ListOptions): Promise<Task[]>;
  get(id: string): Promise<Task | undefined>;
  update(id: string, changes: UpdateTaskBody): Promise<Task | undefined>;
  remove(id: string): Promise<boolean>;
}

export function createTaskRepository(pool: pg.Pool): TaskRepository {
  return {
    async create(input) {
      const { rows } = await pool.query<TaskRow>(
        `INSERT INTO tasks (title, description, status)
         VALUES ($1, $2, COALESCE($3, 'todo'))
         RETURNING ${COLUMNS}`,
        [input.title, input.description ?? null, input.status ?? null],
      );
      const [row] = rows;
      if (!row) throw new Error('INSERT ... RETURNING produced no row');
      return toTask(row);
    },

    async list({ status, limit, offset }) {
      // id breaks created_at ties, so pages never overlap.
      const { rows } = await pool.query<TaskRow>(
        `SELECT ${COLUMNS} FROM tasks
         WHERE ($1::text IS NULL OR status = $1)
         ORDER BY created_at DESC, id DESC
         LIMIT $2 OFFSET $3`,
        [status ?? null, limit, offset],
      );
      return rows.map(toTask);
    },

    async get(id) {
      const { rows } = await pool.query<TaskRow>(`SELECT ${COLUMNS} FROM tasks WHERE id = $1`, [
        id,
      ]);
      return rows[0] && toTask(rows[0]);
    },

    async update(id, changes) {
      const entries = Object.entries(changes).filter(
        (entry): entry is [keyof UpdateTaskBody, string | null] => entry[0] in UPDATABLE_COLUMNS,
      );
      const assignments = entries.map(
        ([field], index) =>
          `${UPDATABLE_COLUMNS[field]} = $${String(index + FIRST_CHANGE_PLACEHOLDER)}`,
      );
      const { rows } = await pool.query<TaskRow>(
        `UPDATE tasks SET ${assignments.join(', ')}, updated_at = now()
         WHERE id = $1
         RETURNING ${COLUMNS}`,
        [id, ...entries.map(([, value]) => value)],
      );
      return rows[0] && toTask(rows[0]);
    },

    async remove(id) {
      const { rowCount } = await pool.query('DELETE FROM tasks WHERE id = $1', [id]);
      return rowCount === 1;
    },
  };
}
