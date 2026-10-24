import { Type } from 'typebox';
import { PATTERNS } from '../patterns.js';

export const TaskStatusSchema = Type.Union(
  [Type.Literal('todo'), Type.Literal('in_progress'), Type.Literal('done')],
  { description: 'Workflow state of the task' },
);

// Match the varchar sizes in the create-tasks migration.
const TITLE_MAX_LENGTH = 200;
const DESCRIPTION_MAX_LENGTH = 2000;

const Title = Type.String({
  minLength: 1,
  maxLength: TITLE_MAX_LENGTH,
  pattern: PATTERNS.notBlankNoNulCharacters.regex,
});
const Description = Type.Union([
  Type.Null(),
  Type.String({ maxLength: DESCRIPTION_MAX_LENGTH, pattern: PATTERNS.noNulCharacters.regex }),
]);

export const TaskSchema = Type.Object({
  id: Type.String({ format: 'uuid' }),
  title: Title,
  description: Description,
  status: TaskStatusSchema,
  createdAt: Type.String({ format: 'date-time' }),
  updatedAt: Type.String({ format: 'date-time' }),
});

export const CreateTaskBodySchema = Type.Object(
  {
    title: Title,
    description: Type.Optional(Description),
    status: Type.Optional(TaskStatusSchema),
  },
  { additionalProperties: false },
);

export const UpdateTaskBodySchema = Type.Object(
  {
    title: Type.Optional(Title),
    description: Type.Optional(Description),
    status: Type.Optional(TaskStatusSchema),
  },
  { additionalProperties: false, minProperties: 1 },
);

export const TaskParamsSchema = Type.Object({ id: Type.String({ format: 'uuid' }) });

export const DEFAULT_PAGE_SIZE = 20;
export const DEFAULT_OFFSET = 0;
const MAX_PAGE_SIZE = 100;
// ponytail: offset pagination degrades on deep pages; switch to keyset (created_at, id) cursors
// if clients ever need to page past this.
const MAX_OFFSET = 10_000;

// Optional so OpenAPI does not mark them required; Ajv fills the defaults.
export const ListTasksQuerySchema = Type.Object(
  {
    status: Type.Optional(TaskStatusSchema),
    limit: Type.Optional(
      Type.Integer({ minimum: 1, maximum: MAX_PAGE_SIZE, default: DEFAULT_PAGE_SIZE }),
    ),
    offset: Type.Optional(
      Type.Integer({ minimum: 0, maximum: MAX_OFFSET, default: DEFAULT_OFFSET }),
    ),
  },
  { additionalProperties: false },
);

export const TaskListSchema = Type.Object({
  items: Type.Array(TaskSchema),
  limit: Type.Integer(),
  offset: Type.Integer(),
});
