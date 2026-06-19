// Backend base URL is provided by the reconciler-injected env at runtime.
// Server-only (used in route handlers / server components) — the browser never
// sees the internal backend address, matching the private-VPC topology.
export const BACKEND_URL = process.env.BACKEND_URL ?? "http://localhost:8080";

export type Lead = {
  id: number;
  name: string;
  email: string;
  company: string | null;
  message: string | null;
  status: string;
  error: string | null;
  created_at: string;
  updated_at: string;
};

export async function backendHealth(): Promise<{ status: string; worker_online: boolean }> {
  const res = await fetch(`${BACKEND_URL}/healthz`, { cache: "no-store" });
  if (!res.ok) throw new Error(`backend ${res.status}`);
  return res.json();
}
