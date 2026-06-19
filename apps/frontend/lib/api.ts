// Backend base URL is provided by the reconciler-injected env at runtime.
// Server-only (used in route handlers / server components) — the browser never
// sees the internal backend address, matching the private-VPC topology.
export const BACKEND_URL = process.env.BACKEND_URL ?? "http://localhost:8080";

export type Lead = {
  id: number;
  first_name: string;
  phone: string;
  email: string;
  company: string;
  status: string;
  invite_sent: boolean;
  invite_sent_at: string | null;
  error: string | null;
  created_at: string;
  updated_at: string;
};

export async function backendHealth(): Promise<{ status: string; worker_online: boolean }> {
  const res = await fetch(`${BACKEND_URL}/healthz`, { cache: "no-store" });
  if (!res.ok) throw new Error(`backend ${res.status}`);
  return res.json();
}
