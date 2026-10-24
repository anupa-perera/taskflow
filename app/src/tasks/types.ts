import type { Static } from 'typebox';
import type {
  CreateTaskBodySchema,
  TaskSchema,
  TaskStatusSchema,
  UpdateTaskBodySchema,
} from './schema.js';

export type Task = Static<typeof TaskSchema>;
export type TaskStatus = Static<typeof TaskStatusSchema>;
export type CreateTaskBody = Static<typeof CreateTaskBodySchema>;
export type UpdateTaskBody = Static<typeof UpdateTaskBodySchema>;
