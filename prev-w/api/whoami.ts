import { getIdentity } from "../cursor/identity.js";

export async function GET(request: Request): Promise<Response> {
  const headers: Record<string, string> = {};
  request.headers.forEach((value, key) => {
    headers[key] = value;
  });
  const viewer = await getIdentity(request);
  return Response.json({ headers, viewer });
}
