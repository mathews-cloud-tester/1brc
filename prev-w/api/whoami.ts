import { getIdentity } from "../cursor/identity";

export default async function handler(request: Request): Promise<Response> {
  const headers: Record<string, string> = {};
  request.headers.forEach((value, name) => {
    headers[name.toLowerCase()] = value;
  });

  const identity = await getIdentity(request);
  const stage = identity.verified ? identity.stage : null;

  return Response.json({ headers, stage });
}
