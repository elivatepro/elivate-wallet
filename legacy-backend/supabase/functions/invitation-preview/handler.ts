import { DomainError } from "../../../src/shared/domain_error.ts";
import {
  failureResponse,
  optionsResponse,
  requestIdFor,
  successResponse,
} from "../_shared/http.ts";
import { invitationTokenDigest } from "../_shared/invitation.ts";

export type PreviewLookup = (
  digest: string,
) => Promise<Readonly<{ data: unknown; error: unknown | null }>>;

function unavailable(): DomainError {
  return new DomainError("not_found", "This invitation is unavailable");
}

export async function handleInvitationPreview(
  request: Request,
  lookup: PreviewLookup,
): Promise<Response> {
  const requestId = requestIdFor(request);
  let response: Response;
  if (request.method === "OPTIONS") {
    response = optionsResponse(request);
  } else {
    try {
      if (request.method !== "POST") {
        throw new DomainError("validation_error", "Method not allowed");
      }
      let body: unknown;
      try {
        const reader = request.body?.getReader();
        if (reader === undefined) throw unavailable();
        const chunks: Uint8Array[] = [];
        let size = 0;
        try {
          while (true) {
            const part = await reader.read();
            if (part.done) break;
            size += part.value.byteLength;
            if (size > 2048) {
              await reader.cancel();
              throw unavailable();
            }
            chunks.push(part.value);
          }
        } finally {
          reader.releaseLock();
        }
        const bytes = new Uint8Array(size);
        let offset = 0;
        for (const chunk of chunks) {
          bytes.set(chunk, offset);
          offset += chunk.byteLength;
        }
        body = JSON.parse(new TextDecoder().decode(bytes));
      } catch {
        throw unavailable();
      }
      if (body === null || typeof body !== "object" || Array.isArray(body)) {
        throw unavailable();
      }
      const token = (body as Record<string, unknown>).token;
      if (
        typeof token !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(token)
      ) throw unavailable();
      const { data, error } = await lookup(await invitationTokenDigest(token));
      if (error !== null) throw new Error("Invitation preview lookup failed");
      if (data === null) throw unavailable();
      if (
        typeof data !== "object" || Array.isArray(data) ||
        typeof (data as Record<string, unknown>).email !== "string"
      ) throw new Error("Invitation preview response is invalid");
      // Return only the approved field even if the database response changes.
      response = successResponse(request, requestId, {
        email: (data as Record<string, unknown>).email as string,
      });
    } catch (error) {
      response = failureResponse(request, requestId, error);
    }
  }
  response.headers.set("cache-control", "no-store");
  response.headers.set("access-control-allow-methods", "POST, OPTIONS");
  response.headers.set(
    "access-control-allow-headers",
    "authorization, apikey, content-type, x-request-id",
  );
  return response;
}
