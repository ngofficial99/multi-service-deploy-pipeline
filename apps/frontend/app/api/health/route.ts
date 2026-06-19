import { NextResponse } from "next/server";
import { backendHealth } from "../../../lib/api";

// Frontend is healthy if it is up AND can reach the backend.
// Used by the VM reconciler's health check.
export async function GET() {
  try {
    const h = await backendHealth();
    return NextResponse.json({ status: "ok", backend: h });
  } catch {
    return NextResponse.json({ status: "backend_unreachable" }, { status: 503 });
  }
}
