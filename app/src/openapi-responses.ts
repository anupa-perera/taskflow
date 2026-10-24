import { Type } from 'typebox';
import { HTTP_STATUS } from './http-status.js';

// Advertises the media type the error handler actually sends.
export function problemResponse(description: string) {
  return {
    description,
    content: { 'application/problem+json': { schema: Type.Ref('ProblemDetails') } },
  };
}

export const BadRequestResponse = {
  [HTTP_STATUS.BAD_REQUEST]: problemResponse('The request failed validation'),
};

export const notFoundResponse = (resource: string) => ({
  [HTTP_STATUS.NOT_FOUND]: problemResponse(`No ${resource} with this id`),
});
